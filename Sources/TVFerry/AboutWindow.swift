import Cocoa
import SwiftUI

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    .accessibilityHidden(true)
                Text(AppInfo.name).font(.system(size: 24, weight: .bold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Text(AppInfo.tagline)
                    .font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                    .padding(.top, 6)
                Text(AppInfo.summary)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 20)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").font(.system(size: 20)).foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Made by \(AppInfo.author)").font(.system(size: 13, weight: .semibold))
                        Link(AppInfo.email, destination: URL(string: "mailto:\(AppInfo.email)")!).font(.system(size: 12)).foregroundStyle(Palette.accent)
                    }
                    Spacer()
                }
                .padding(12)
                Divider().padding(.leading, 44)
                row("Send Feedback…", icon: "bubble.left.and.bubble.right") { FeedbackWindowController.shared.show() }
                Divider().padding(.leading, 44)
                row("Check for Updates…", icon: "arrow.down.circle") { Updates.check(userInitiated: true) }
                Divider().padding(.leading, 44)
                row("TV Ferry on GitHub", icon: "chevron.left.forwardslash.chevron.right") { NSWorkspace.shared.open(AppInfo.repo) }
                Divider().padding(.leading, 44)
                row("Report an Issue", icon: "exclamationmark.bubble") { NSWorkspace.shared.open(AppInfo.issues) }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .padding(.horizontal, 20)

            Text("© \(AppInfo.year) \(AppInfo.author) · \(AppInfo.license) · Free and open source")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 18)
        }
        .frame(width: 400)
        .background(Palette.content)
        .tint(Palette.accent)
    }

    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            let w = NSWindow(contentViewController: host)
            w.title = "About \(AppInfo.name)"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
