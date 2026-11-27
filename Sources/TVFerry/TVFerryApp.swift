import SwiftUI
import AppKit

@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings = ConnectionSettings()
    lazy var queue = TransferQueue(settings: settings)
    lazy var monitor = ConnectionMonitor(settings: settings)
}

/// Lets you drop files onto the Dock icon, or use "Open With → TV Ferry" in Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let m = AppModel.shared
            m.queue.add(urls: urls, to: m.settings.remoteFolder)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { UpdatePrefs.shared.appearance.apply() }
        // Test hook: TVFERRY_DEBUG=1 TVFERRY_ENQUEUE="<path>\n<path>" queues files at launch (used for screenshots).
        let env = ProcessInfo.processInfo.environment
        if env["TVFERRY_DEBUG"] == "1", let list = env["TVFERRY_ENQUEUE"], !list.isEmpty {
            let urls = list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            MainActor.assumeIsolated { AppModel.shared.queue.add(urls: urls, to: AppModel.shared.settings.remoteFolder) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.offerAutoUpdates() }
    }

    /// Asked once, after the TV has been set up (so it doesn't pile onto the first-run setup sheet).
    @MainActor private func offerAutoUpdates() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "askedAutoUpdates") else { Updates.checkIfDue(); return }
        guard !AppModel.shared.settings.host.isEmpty else { return }
        d.set(true, forKey: "askedAutoUpdates")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Check for TV Ferry updates automatically?"
        alert.informativeText = "Once a day TV Ferry would ask GitHub whether a newer version exists and tell you if there is one. Nothing about you or your Mac is sent. You can change this later from the TV Ferry menu."
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Not Now")
        UpdatePrefs.shared.autoCheck = alert.runModal() == .alertFirstButtonReturn
    }

    /// With the menu bar panel on, TV Ferry keeps running (and sending) after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UpdatePrefs.shared.showInMenuBar }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let q = MainActor.assumeIsolated { AppModel.shared.queue }
        let busy = MainActor.assumeIsolated { q.isRunning }
        guard busy else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Files are still being sent to the TV."
        a.informativeText = "If you quit now, the current file stops part-way. Next time you send it, TV Ferry resumes from where it stopped."
        a.addButton(withTitle: "Keep Sending")
        a.addButton(withTitle: "Quit")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct TVFerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var prefs = UpdatePrefs.shared

    var body: some Scene {
        let m = AppModel.shared
        Window("TV Ferry", id: "main") {
            ContentView(settings: m.settings, queue: m.queue, monitor: m.monitor)
                .frame(minWidth: 780, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 580)
        .commands { AppCommands(updates: prefs) }

        // SwiftUI writes this binding back while it draws; ignoring writes that change nothing avoids a redraw loop.
        MenuBarExtra(isInserted: Binding(get: { prefs.showInMenuBar },
                                         set: { if $0 != prefs.showInMenuBar { prefs.showInMenuBar = $0 } })) {
            MenuBarPanel(settings: m.settings, queue: m.queue, monitor: m.monitor)
        } label: {
            MenuBarIcon(queue: m.queue)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(prefs: prefs, settings: m.settings)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var updates: UpdatePrefs

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About TV Ferry") { AboutWindowController.shared.show() }
            Button("Check for Updates…") { Updates.check(userInitiated: true) }
            Toggle("Check for Updates Automatically", isOn: $updates.autoCheck)
        }
        CommandGroup(after: .appSettings) {
            Picker("Appearance", selection: $updates.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Show in Menu Bar", isOn: $updates.showInMenuBar)
            Toggle("Convert Videos the TV May Not Play Without Asking", isOn: $updates.autoConvert)
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { FeedbackWindowController.shared.show() }
            Button("Report an Issue on GitHub") { NSWorkspace.shared.open(AppInfo.issues) }
            Button("TV Ferry on GitHub") { NSWorkspace.shared.open(AppInfo.repo) }
            Divider()
            Button("Email \(AppInfo.author)") { NSWorkspace.shared.open(AppInfo.feedbackURL) }
        }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--check-video") {
            // Prints whether each file may not play on a TV.
            Task {
                for path in args[(i + 1)...] {
                    let issue = await VideoCheck.inspect(URL(fileURLWithPath: path))
                    print("\((path as NSString).lastPathComponent): \(issue?.summary ?? "OK")")
                }
                exit(0)
            }
            dispatchMain()
        } else if let i = args.firstIndex(of: "--convert-video"), args.count > i + 2 {
            Task {
                do {
                    try await VideoCheck.Conversion().run(input: URL(fileURLWithPath: args[i + 1]),
                                                          output: URL(fileURLWithPath: args[i + 2])) { _ in }
                    print("converted"); exit(0)
                } catch { print("convert error:", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        } else if let i = args.firstIndex(of: "--check-update") {
            // Prints what the update checker sees on GitHub. Optional arg: pretend current version.
            let current = args.count > i + 1 ? args[i + 1] : AppInfo.version
            Task {
                do {
                    guard let r = try await Updates.fetchLatest() else { print("no release found"); exit(1) }
                    print("latest=\(r.version) current=\(current) newer=\(Updates.isNewer(r.version, than: current)) download=\(r.download?.absoluteString ?? "-")")
                    exit(0)
                } catch { print("error:", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        } else if let i = args.firstIndex(of: "--feedback-test") {
            // Posts a test message to the endpoint given (never the real inbox unless you pass it).
            UserDefaults.standard.set(args[i + 1], forKey: "feedbackEndpointOverride")
            Task {
                do {
                    try await FeedbackSender.send(kind: .bug, message: "test message", replyTo: "tester@example.com",
                                                  includeSystemInfo: true, screenshot: Data([0xFF, 0xD8, 0xFF]))
                    print("feedback sent OK to", AppInfo.feedbackEndpoint.absoluteString); exit(0)
                } catch { print("feedback error:", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        } else if let i = args.firstIndex(of: "--selftest-adb") {
            SelfTest.runADB(Array(args[(i + 1)...]))
        } else if let i = args.firstIndex(of: "--selftest") {
            SelfTest.run(Array(args[(i + 1)...]))
        } else {
            TVFerryApp.main()
        }
    }
}

/// `TVFerry --selftest <host> <port> <user> <password> <remoteDir> <file-or-folder>...`
/// Runs the real queue without the window — used to check transfers end to end.
enum SelfTest {
    static func run(_ a: [String]) {
        guard a.count >= 6, let port = Int(a[1]) else {
            print("usage: --selftest host port user password remoteDir paths..."); exit(2)
        }
        let cfg = FTPConfig(host: a[0], port: port, user: a[2], password: a[3])
        Task { @MainActor in
            if let err = await FTPClient.test(config: cfg) { print("CONNECT FAIL:", err); exit(1) }
            print("connected; root:", (try? await FTPClient.list("/", config: cfg).map(\.name)) ?? [])
            await drive(TransferQueue(settings: ConnectionSettings(ephemeral: cfg, folder: a[4])),
                        urls: a[5...].map { URL(fileURLWithPath: $0) }, folder: a[4])
        }
        dispatchMain()
    }

    /// `TVFerry --selftest-adb <host> <port> <remoteDir> <file-or-folder>...` — the same over network debugging.
    static func runADB(_ a: [String]) {
        guard a.count >= 4, let port = Int(a[1]) else {
            print("usage: --selftest-adb host port remoteDir paths..."); exit(2)
        }
        let cfg = FTPConfig(host: a[0], port: port, user: "", password: "")
        let remote = Remote(kind: .adb, ftp: cfg, adbPort: port)
        Task { @MainActor in
            if let err = await RemoteFS.test(remote) { print("CONNECT FAIL:", err); exit(1) }
            print("connected; root:", (try? await RemoteFS.list("/", on: remote).map(\.name)) ?? [])
            await drive(TransferQueue(settings: ConnectionSettings(ephemeral: cfg, folder: a[2], kind: .adb)),
                        urls: a[3...].map { URL(fileURLWithPath: $0) }, folder: a[2])
        }
        dispatchMain()
    }

    @MainActor private static func drive(_ q: TransferQueue, urls: [URL], folder: String) async {
        do {  // keeps the body's indentation
            q.add(urls: urls, to: folder)
            if let n = q.lastNotice { print("notice:", n) }
            var lastPrint = Date.distantPast
            while q.isRunning {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Date().timeIntervalSince(lastPrint) > 0.5, let cur = q.items.first(where: { $0.state == .uploading }) {
                    print(String(format: "  … %@ %.0f%%", cur.remoteName, cur.fraction * 100))
                    lastPrint = Date()
                }
            }
            var bad = 0
            for i in q.items {
                print("\(i.state) | \(i.originalName) -> \(i.remotePath) | \(i.bytesSent)/\(i.size) resumedFrom=\(i.resumedFrom) verified=\(i.verified)")
                if case .failed = i.state { bad += 1 }
            }
            exit(bad == 0 ? 0 : 1)
        }
    }
}
