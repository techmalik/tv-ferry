import SwiftUI
import AppKit

/// Light, Dark, or whatever macOS is set to.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: return "Match System"; case .light: return "Light"; case .dark: return "Dark" }
    }
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// TV Ferry's own colours, from the design canvas (option B), with dark-mode pairs.
/// The app uses these instead of the Mac's accent colour, so it looks the same on every Mac.
enum Palette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
    static let accent = dynamic(0x0064D2, 0x0A84FF)
    static let accentSoft = dynamic(0xEAF2FD, 0x173A5E)     // TV tile
    static let sidebar = dynamic(0xEEF0F4, 0x232326)
    static let sidebarCard = dynamic(0xFFFFFF, 0x2C2C2E)
    static let content = dynamic(0xFFFFFF, 0x1C1C1E)
    static let rowDivider = dynamic(0xF0F0F3, 0x2C2C2E)
    static let border = dynamic(0xD2D2D7, 0x3A3A3C)
    static let textPrimary = dynamic(0x1D1D1F, 0xF2F2F7)
    static let textSecondary = dynamic(0x6E6E73, 0xAEAEB2)
    static let success = dynamic(0x1E7F3A, 0x30D158)
    static let warning = dynamic(0xB25000, 0xFFB340)
    static let warningRow = dynamic(0xFFF8F0, 0x3A2A16)     // "may not play" row
    static let danger = dynamic(0xC4261D, 0xFF6961)
    static let track = dynamic(0xE5E5EA, 0x3A3A3C)          // progress bar background
}

/// Whether the TV answers, shared by the main window and the menu bar panel.
@MainActor
final class ConnectionMonitor: ObservableObject {
    enum Status: Equatable { case unknown, checking, ok, failed(String) }
    @Published private(set) var status: Status = .unknown
    let settings: ConnectionSettings

    init(settings: ConnectionSettings) { self.settings = settings }

    func check() {
        guard settings.remote.isComplete else { status = .unknown; return }
        status = .checking
        let r = settings.remote
        Task {
            let err = await RemoteFS.test(r)
            guard r == settings.remote else { return }   // settings changed meanwhile; a newer check is running
            status = err.map(Status.failed) ?? .ok
        }
    }

    var color: Color {
        switch status {
        case .ok: return Palette.success
        case .failed: return Palette.danger
        case .checking: return Palette.warning
        case .unknown: return Palette.textSecondary
        }
    }

    var text: String {
        switch status {
        case .ok: return "Connected"
        case .checking: return "Checking…"
        case .failed(let m): return m
        case .unknown:
            if settings.host.isEmpty { return "Set up your TV" }
            return settings.kind == .adb ? "Turn on Network debugging on the TV" : "Start \"Access from network\" on the TV"
        }
    }
}

/// The translucent sidebar material macOS uses in Finder, Mail and Music.
struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The TV glyph in a soft rounded tile.
struct TVTile: View {
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(Palette.accentSoft)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "tv").font(.system(size: size * 0.48)).foregroundStyle(Palette.accent))
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
}

/// A thin progress bar in the given colour.
struct ThinBar: View {
    var value: Double
    var tint: Color = Palette.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(tint).frame(width: max(3, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// The one-line queue summary shared by the window and the menu bar panel.
@MainActor
enum QueueSummary {
    static func text(_ queue: TransferQueue, settings: ConnectionSettings) -> String {
        if queue.pendingCount > 0 {
            var s = "\(queue.pendingCount) to send · \(Fmt.bytes(queue.remainingBytes)) left"
            if queue.currentSpeed > 0 {
                s += " · \(Fmt.bytes(Int64(queue.currentSpeed)))/s · \(Fmt.eta(Double(queue.remainingBytes) / queue.currentSpeed))"
            }
            if queue.paused { s += " · paused" }
            return s
        }
        if !queue.items.isEmpty {
            return queue.failedCount > 0 ? "Finished with \(queue.failedCount) problem(s)" : "All done"
        }
        return "Files go to \(settings.remoteFolder) on \(settings.displayName)"
    }
}
