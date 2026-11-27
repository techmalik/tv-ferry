import SwiftUI
import AppKit

/// The menu bar icon: a TV, filled while files are being sent.
struct MenuBarIcon: View {
    @ObservedObject var queue: TransferQueue
    var body: some View {
        Image(systemName: queue.isRunning ? "tv.fill" : "tv")
            .accessibilityLabel(queue.isRunning ? "TV Ferry, sending" : "TV Ferry")
    }
}

/// The panel under the menu bar icon: drop files, see what's sending, and get back to the window.
struct MenuBarPanel: View {
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var queue: TransferQueue
    @ObservedObject var monitor: ConnectionMonitor
    @Environment(\.openWindow) private var openWindow
    @LocalState private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TVTile(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(color: monitor.color)
                        Text(monitor.status == .ok ? "Connected · into \(settings.remoteFolder)" : monitor.text)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            VStack(spacing: 4) {
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: 20, weight: .light))
                Text("Drop files here").font(.system(size: 13, weight: .medium))
                Button("or choose files…") { chooseFiles() }.buttonStyle(.link).font(.caption)
            }
            .foregroundStyle(dropTargeted ? Palette.accent : Color.secondary)
            .frame(maxWidth: .infinity).frame(height: 96)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(dropTargeted ? Palette.accent : Palette.border)
            )
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                queue.add(urls: urls, to: settings.remoteFolder)
                return true
            } isTargeted: { dropTargeted = $0 }
            .padding(.horizontal, 12)

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    let shown = visibleItems
                    if !shown.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(shown) { MiniRow(item: $0, queue: queue) }
                        }
                        .padding(.horizontal, 6).padding(.top, 8)
                    }
                    Divider().padding(.top, 8)
                    HStack(spacing: 10) {
                        Text(QueueSummary.text(queue, settings: settings)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).monospacedDigit()
                        Spacer(minLength: 4)
                        if queue.paused {
                            Button("Resume") { queue.resume() }.buttonStyle(.borderless).font(.caption)
                        } else if queue.isRunning {
                            Button("Pause") { queue.pause() }.buttonStyle(.borderless).font(.caption)
                        }
                        Button("Open TV Ferry") {
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        .frame(width: 340)
        .tint(Palette.accent)
    }

    /// What's in progress first, then the most recently finished, five at most.
    private var visibleItems: [TransferItem] {
        let active = queue.items.filter { !$0.state.isFinished }
        let finished = queue.items.filter { $0.state.isFinished }.suffix(5)
        return Array((active + finished.reversed()).prefix(5))
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to TV"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { queue.add(urls: panel.urls, to: settings.remoteFolder) }
    }
}

/// One file in the menu bar panel.
private struct MiniRow: View {
    @ObservedObject var item: TransferItem
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.remoteName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                trailing
            }
            switch item.state {
            case .uploading: ThinBar(value: item.fraction)
            case .converting: ThinBar(value: item.convertProgress, tint: Palette.warning)
            case .needsChoice:
                Text("May not play on the TV").font(.caption).foregroundStyle(Palette.warning)
                HStack(spacing: 6) {
                    Button("Convert & Send") { queue.choose(item, convert: true) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("As Is") { queue.choose(item, convert: false) }.controlSize(.small)
                }
            default: EmptyView()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(item.state == .needsChoice ? Palette.warningRow : Color.clear))
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .uploading: Text("\(Int(item.fraction * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .converting: Text("Converting \(Int(item.convertProgress * 100))%").font(.caption).foregroundStyle(Palette.warning)
        case .checking: Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .needsChoice: EmptyView()
        case .done: Text(item.verified ? "✓ Sent" : "Sent · not checked").font(.caption).foregroundStyle(item.verified ? Palette.success : Palette.warning)
        case .skipped: Text("Already on TV").font(.caption).foregroundStyle(.secondary)
        case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .failed(let why): Text("Failed").font(.caption).foregroundStyle(Palette.danger).help(why)
        }
    }
}
