import Foundation
import SwiftUI

@MainActor
final class TransferItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued, checking, uploading, done, skipped(String), failed(String), cancelled
        /// Video may not play on the TV; waiting for "Convert & Send" or "Send As Is".
        case needsChoice
        case converting
        var isFinished: Bool {
            switch self { case .done, .skipped, .failed, .cancelled: return true; default: return false }
        }
    }

    let id = UUID()
    let localURL: URL
    var remotePath: String
    /// Bytes to send: the original's size, or the converted copy's once it exists.
    var size: Int64
    let originalName: String
    var remoteName: String { (remotePath as NSString).lastPathComponent }

    @Published var state: State = .queued
    @Published var bytesSent: Int64 = 0
    @Published var speed: Double = 0      // bytes / second
    @Published var resumedFrom: Int64 = 0
    /// After a send: whether the TV confirmed it holds exactly as many bytes as the Mac.
    @Published var verified = false

    // Video compatibility
    @Published var issue: VideoIssue?
    @Published var convert = false
    @Published var convertProgress: Double = 0
    var convertedURL: URL?
    var checkTask: Task<Void, Never>?
    /// What actually gets uploaded.
    var sourceURL: URL { convertedURL ?? localURL }

    var fraction: Double { size > 0 ? Double(bytesSent) / Double(size) : (state == .done ? 1 : 0) }
    var wasRenamed: Bool { originalName != remoteName && !convert }

    init(localURL: URL, remotePath: String, size: Int64) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.size = size
        self.originalName = localURL.lastPathComponent
    }
}

@MainActor
final class TransferQueue: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published private(set) var isRunning = false
    @Published var paused = false
    @Published var lastNotice: String?

    private var current: TransferRun?
    private var currentConversion: VideoCheck.Conversion?
    private var currentItem: TransferItem?
    private var sleepActivity: NSObjectProtocol?
    let settings: ConnectionSettings

    init(settings: ConnectionSettings) {
        self.settings = settings
        // Converted copies left over from a previous run are no longer needed.
        if let old = try? FileManager.default.contentsOfDirectory(at: VideoCheck.workFolder, includingPropertiesForKeys: nil) {
            old.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

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
        if VideoCheck.isCheckable(item.localURL) {
            item.checkTask = Task { [weak self] in await self?.checkVideo(item) }
        }
    }

    // MARK: Video compatibility

    private func checkVideo(_ item: TransferItem) async {
        guard let issue = await VideoCheck.inspect(item.localURL) else { return }
        item.issue = issue
        if Prefs.autoConvertVideos {
            setConvert(item)
        } else if item.state == .queued {
            item.state = .needsChoice
        }
    }

    private func setConvert(_ item: TransferItem) {
        item.convert = true
        let ext = (item.remotePath as NSString).pathExtension.lowercased()
        if ext != "mp4" && ext != "m4v" {
            item.remotePath = (item.remotePath as NSString).deletingPathExtension + ".mp4"
        }
    }

    /// The user's answer for a video that may not play on the TV.
    func choose(_ item: TransferItem, convert: Bool) {
        if convert { setConvert(item) }
        item.state = .queued
        startIfNeeded()
    }

    func convertAll() {
        for i in items where i.state == .needsChoice { setConvert(i); i.state = .queued }
        startIfNeeded()
    }

    var needsChoiceCount: Int { items.filter { $0.state == .needsChoice }.count }

    private func discardConverted(_ item: TransferItem) {
        if let u = item.convertedURL { try? FileManager.default.removeItem(at: u) }
        item.convertedURL = nil
    }

    // MARK: Control

    func startIfNeeded() {
        guard !isRunning, !paused else { return }
        guard settings.remote.isComplete else { lastNotice = "Set the TV's address first."; return }
        isRunning = true
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                              reason: "Sending files to TV")
        Task { await loop() }
    }

    func pause() {
        paused = true
        if let item = currentItem { item.state = .queued }
        current?.cancel()
        currentConversion?.cancel()
    }

    func resume() {
        paused = false
        startIfNeeded()
    }

    func cancel(_ item: TransferItem) {
        if item === currentItem { current?.cancel(); currentConversion?.cancel() }
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

    func clearFinished() {
        for i in items where i.state.isFinished { discardConverted(i) }
        items.removeAll { $0.state.isFinished }
    }

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
        let config = settings.remote
        currentItem = item

        // Wait for the video check, which may decide the user should choose first.
        if let t = item.checkTask { await t.value; item.checkTask = nil }
        guard item.state == .queued else { return }

        item.state = .checking
        item.speed = 0

        guard FileManager.default.isReadableFile(atPath: item.localURL.path) else {
            item.state = .failed("The file on this Mac can't be read (moved or deleted?).")
            return
        }

        if item.convert, item.convertedURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            item.state = .converting
            item.convertProgress = 0
            let out = VideoCheck.workFolder.appendingPathComponent(UUID().uuidString + ".mp4")
            let conversion = VideoCheck.Conversion()
            currentConversion = conversion
            do {
                try await conversion.run(input: item.localURL, output: out) { [weak item] p in item?.convertProgress = p }
                currentConversion = nil
                item.convertedURL = out
                let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
                item.size = size
                item.bytesSent = 0
            } catch {
                currentConversion = nil
                if error is CancellationError {
                    if item.state != .cancelled { item.state = paused ? .queued : .cancelled }
                } else {
                    item.state = .failed("Couldn't convert the video: \(error.localizedDescription)")
                }
                return
            }
            item.state = .checking
        }

        let remoteSize = await RemoteFS.size(item.remotePath, on: config)
        if item.state == .cancelled || paused { if paused { item.state = .queued }; return }

        var resumeFrom: Int64 = 0
        if let rs = remoteSize {
            if rs == item.size {
                if settings.skipExisting {
                    PartialUploads.finish(config, remotePath: item.remotePath)
                    item.bytesSent = item.size
                    item.state = .skipped("Already on TV")
                    return
                }
            } else if rs > 0 && rs < item.size, RemoteFS.supportsResume(config),
                      PartialUploads.canResume(config, remotePath: item.remotePath, local: item.sourceURL, size: item.size) {
                // TV Ferry was interrupted sending this same, unchanged file: carry on from there.
                // Any other smaller file with this name (an older copy, a different movie) is
                // replaced from the start instead. A converted copy resumes only while the exact
                // copy it started from still exists; a fresh re-encode isn't byte-identical.
                resumeFrom = rs
            }
        }

        PartialUploads.begin(config, remotePath: item.remotePath, local: item.sourceURL, size: item.size)
        item.resumedFrom = resumeFrom
        item.verified = false
        item.bytesSent = resumeFrom
        item.state = .uploading

        var lastTick = Date()
        var lastBytes = resumeFrom
        let total = item.size
        let run = RemoteFS.makeUpload(local: item.sourceURL, remotePath: item.remotePath,
                                      resumeFrom: resumeFrom, size: total, on: config) { [weak item] frac in
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
            item.state = .failed(RemoteFS.friendlyMessage(result, on: config, fileSize: item.size))
            return
        }
        // Verify: the TV should now hold exactly as many bytes as the Mac.
        // If the TV won't report the size, say so rather than claiming the file was checked.
        let remoteAfter = await RemoteFS.size(item.remotePath, on: config)
        if let rs = remoteAfter, rs != item.size {
            item.state = .failed("Size mismatch after upload (TV has \(rs) of \(item.size) bytes). Press Retry to resume.")
            return
        }
        item.verified = remoteAfter != nil
        PartialUploads.finish(config, remotePath: item.remotePath)
        item.bytesSent = item.size
        item.speed = 0
        item.state = .done
        discardConverted(item)
    }
}
