import SwiftUI
import AppKit

@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings = ConnectionSettings()
    lazy var queue = TransferQueue(settings: settings)
}

/// Lets you drop files onto the Dock icon, or use "Open With → TV Ferry" in Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let m = AppModel.shared
            m.queue.add(urls: urls, to: m.settings.remoteFolder)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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

    var body: some Scene {
        Window("TV Ferry", id: "main") {
            ContentView(settings: AppModel.shared.settings, queue: AppModel.shared.queue)
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
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
            let q = TransferQueue(settings: ConnectionSettings(ephemeral: cfg, folder: a[4]))
            q.add(urls: a[5...].map { URL(fileURLWithPath: $0) }, to: a[4])
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
                print("\(i.state) | \(i.originalName) -> \(i.remotePath) | \(i.bytesSent)/\(i.size) resumedFrom=\(i.resumedFrom)")
                if case .failed = i.state { bad += 1 }
            }
            exit(bad == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
