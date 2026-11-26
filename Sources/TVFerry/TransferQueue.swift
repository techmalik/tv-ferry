import Foundation
import SwiftUI

@MainActor
final class TransferItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued, checking, uploading, done, skipped(String), failed(String), cancelled
        var isFinished: Bool {
            switch self { case .done, .skipped, .failed, .cancelled: return true; default: return false }
        }
    }

    let id = UUID()
    let localURL: URL
    let remotePath: String
    let size: Int64
    let originalName: String
    let remoteName: String

    @Published var state: State = .queued
    @Published var bytesSent: Int64 = 0
    @Published var speed: Double = 0      // bytes / second
    @Published var resumedFrom: Int64 = 0

    var fraction: Double { size > 0 ? Double(bytesSent) / Double(size) : (state == .done ? 1 : 0) }
    var wasRenamed: Bool { originalName != remoteName }

    init(localURL: URL, remotePath: String, size: Int64) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.size = size
        self.originalName = localURL.lastPathComponent
        self.remoteName = (remotePath as NSString).lastPathComponent
    }
}

@MainActor
final class TransferQueue: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published private(set) var isRunning = false
    @Published var paused = false
    @Published var lastNotice: String?

    private var current: CurlRun?
    private var currentItem: TransferItem?
    private var sleepActivity: NSObjectProtocol?
    let settings: ConnectionSettings

    init(settings: ConnectionSettings) { self.settings = settings }

    // MARK: Adding

    /// Expands dropped files and folders into individual uploads, keeping folder structure,
    /// skipping macOS metadata, and making every path component Android-safe.
    func add(urls: [URL], to remoteDir: String) {
        let fm = FileManager.default
        var added = 0, skippedJunk = 0
        let base = "/" + remoteDir.split(separator: "/").joined(separator: "/")
        func join(_ a: String, _ b: String) -> String { a == "/" ? "/" + b : a + "/" + b }

        for url in urls {
            let name = url.lastPathComponent
            if NameSanitizer.isJunk(name) { skippedJunk += 1; continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let rootRemote = join(base, NameSanitizer.sanitize(name))
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                let rootComps = url.standardizedFileURL.pathComponents.count
                for case let f as URL in e {
                    if NameSanitizer.isJunk(f.lastPathComponent) { skippedJunk += 1; continue }
                    guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    let rel = f.standardizedFileURL.pathComponents.dropFirst(rootComps).map(NameSanitizer.sanitize)
                    let remote = rel.reduce(rootRemote) { join($0, $1) }
                    append(TransferItem(localURL: f, remotePath: remote, size: Int64(v.fileSize ?? 0)))
                    added += 1
                }
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                append(TransferItem(localURL: url, remotePath: join(base, NameSanitizer.sanitize(name)), size: Int64(size)))
                added += 1
            }
        }
        if skippedJunk > 0 { lastNotice = "Skipped \(skippedJunk) macOS system file(s) (.DS_Store etc.)." }
        if added > 0 { startIfNeeded() }
    }

    private func append(_ item: TransferItem) {
        // Don't queue the same destination twice while it's still pending.
        if items.contains(where: { $0.remotePath == item.remotePath && !$0.state.isFinished }) { return }
        items.append(item)
    }

    // MARK: Control

    func startIfNeeded() {
        guard !isRunning, !paused else { return }
        guard settings.config.isComplete else { lastNotice = "Set the TV's address first."; return }
        isRunning = true
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                              reason: "Sending files to TV")
        Task { await loop() }
    }

    func pause() {
        paused = true
        if let item = currentItem { item.state = .queued }
        current?.cancel()
    }

    func resume() {
        paused = false
        startIfNeeded()
    }

    func cancel(_ item: TransferItem) {
        if item === currentItem { current?.cancel() }
        item.state = .cancelled
    }

    func retry(_ item: TransferItem) {
        item.state = .queued
        item.speed = 0
        startIfNeeded()
    }

    func retryFailed() {
        for i in items { if case .failed = i.state { i.state = .queued } else if i.state == .cancelled { i.state = .queued } }
        startIfNeeded()
    }

    func clearFinished() { items.removeAll { $0.state.isFinished } }

    // MARK: Totals

    var pendingCount: Int { items.filter { !$0.state.isFinished }.count }
    var remainingBytes: Int64 { items.filter { !$0.state.isFinished }.reduce(0) { $0 + max(0, $1.size - $1.bytesSent) } }
    var currentSpeed: Double { currentItem?.speed ?? 0 }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return $0.state == .cancelled }.count }

    // MARK: Worker

    private func loop() async {
        while !paused, let item = items.first(where: { $0.state == .queued }) {
            await upload(item)
        }
        isRunning = false
        currentItem = nil
        current = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a); sleepActivity = nil }
    }

    private func upload(_ item: TransferItem) async {
        let config = settings.config
        currentItem = item
        item.state = .checking
        item.speed = 0

        guard FileManager.default.isReadableFile(atPath: item.localURL.path) else {
            item.state = .failed("The file on this Mac can't be read (moved or deleted?).")
            return
        }

        let remoteSize = await FTPClient.size(item.remotePath, config: config)
        if item.state == .cancelled || paused { if paused { item.state = .queued }; return }

        var resumeFrom: Int64 = 0
        if let rs = remoteSize {
            if rs == item.size {
                if settings.skipExisting {
                    item.bytesSent = item.size
                    item.state = .skipped("Already on TV")
                    return
                }
            } else if rs > 0 && rs < item.size {
                resumeFrom = rs   // a previous transfer was interrupted: carry on from there
            }
        }

        item.resumedFrom = resumeFrom
        item.bytesSent = resumeFrom
        item.state = .uploading

        var lastTick = Date()
        var lastBytes = resumeFrom
        let total = item.size
        let run = FTPClient.makeUpload(local: item.localURL, remotePath: item.remotePath,
                                       resumeFrom: resumeFrom, config: config) { [weak item] frac in
            Task { @MainActor in
                // curl reports a share of the WHOLE file (even when resuming) and emits a
                // stray "100%" on its first tick, so ignore 100% until the transfer actually ends.
                guard let item, item.state == .uploading, frac < 1 else { return }
                let sent = max(resumeFrom, Int64(Double(total) * frac))
                item.bytesSent = sent
                let now = Date()
                let dt = now.timeIntervalSince(lastTick)
                if dt >= 0.7 {
                    let inst = Double(sent - lastBytes) / dt
                    item.speed = item.speed == 0 ? inst : item.speed * 0.7 + inst * 0.3
                    lastTick = now
                    lastBytes = sent
                }
            }
        }
        current = run
        let result = await run.run()
        current = nil

        if result.cancelled {
            if item.state != .cancelled { item.state = paused ? .queued : .cancelled }
            return
        }
        guard result.ok else {
            item.state = .failed(FTPClient.friendlyMessage(code: result.status, raw: result.stderr, fileSize: item.size))
            return
        }
        // Verify: the TV should now hold exactly as many bytes as the Mac.
        if let rs = await FTPClient.size(item.remotePath, config: config), rs != item.size {
            item.state = .failed("Size mismatch after upload (TV has \(rs) of \(item.size) bytes). Press Retry to resume.")
            return
        }
        item.bytesSent = item.size
        item.speed = 0
        item.state = .done
    }
}
