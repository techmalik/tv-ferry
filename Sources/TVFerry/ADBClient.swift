import Foundation

struct ADBError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Sends files over Android's network debugging (adb), using Google's own `adb` tool.
/// Once network debugging is on and this Mac is allowed, it works whenever the TV is on:
/// no app needs to be open on the TV. Files go to the TV's internal storage (/sdcard).
enum ADBClient {
    // MARK: Finding and installing adb

    /// Google's official download of Android SDK Platform-Tools for macOS.
    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    static let termsURL = URL(string: "https://developer.android.com/tools/releases/platform-tools")!

    /// Where TV Ferry keeps its own copy, if it downloaded one.
    static var installDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TV Ferry/Platform Tools", isDirectory: true)
    }

    /// An adb already on this Mac (Homebrew, Android Studio) wins, so TV Ferry shares its adb server
    /// instead of fighting it over versions; otherwise TV Ferry's own copy.
    static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if env["TVFERRY_DEBUG"] == "1", let p = env["TVFERRY_ADB"], !p.isEmpty {   // used by the end-to-end tests
            return URL(fileURLWithPath: p)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                          home + "/Library/Android/sdk/platform-tools/adb",
                          installDir.appendingPathComponent("platform-tools/adb").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static let missingMessage = "TV Ferry needs Google's adb tool for network debugging. Open Connection… and click Download adb."

    /// Downloads Platform-Tools from Google into Application Support and unpacks it.
    static func install() async throws {
        let (tmp, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ADBError("Google's download server didn't answer. Try again later, or install adb with Homebrew (brew install android-platform-tools).")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: installDir)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tmp.path, installDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, locate() != nil else {
            throw ADBError("Couldn't unpack the adb download.")
        }
    }

    // MARK: Running adb

    private static var serverStarted = false

    /// Starts adb's background server once, with its output going nowhere, so later commands never
    /// wait on a server process that holds their output pipes open.
    private static func startServerIfNeeded(_ adb: URL) {
        guard !serverStarted else { return }
        let p = Process()
        p.executableURL = adb
        p.arguments = ["start-server"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit(); serverStarted = true }
    }

    /// Runs adb with a time limit (a TV that's off can leave adb waiting for a long time).
    static func run(_ args: [String], timeout: TimeInterval = 20) async -> CurlResult {
        guard let adb = locate() else {
            return CurlResult(status: -2, stdout: Data(), stderr: missingMessage, cancelled: false)
        }
        await Task.detached { startServerIfNeeded(adb) }.value
        let p = ProcessRun(executable: adb, arguments: args)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { p.cancel() }
        }
        let r = await p.run()
        timer.cancel()
        if r.cancelled {
            return CurlResult(status: 28, stdout: r.stdout, stderr: r.stderr + "\nadb timed out", cancelled: false)
        }
        return r
    }

    static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 20) async -> CurlResult {
        await run(["-s", serial, "shell", command], timeout: timeout)
    }

    private static func text(_ r: CurlResult) -> String {
        String(decoding: r.stdout, as: UTF8.self) + "\n" + r.stderr
    }

    /// Single-quotes a string for the TV's shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// TV Ferry's paths ("/Movies/Film.mkv") live in the TV's internal storage.
    static func androidPath(_ path: String) -> String {
        let comps = path.split(separator: "/")
        return "/sdcard" + (comps.isEmpty ? "" : "/" + comps.joined(separator: "/"))
    }

    /// nil once the TV is connected and has allowed this Mac; otherwise what to do about it.
    static func connect(_ serial: String) async -> String? {
        let c = await run(["connect", serial], timeout: 15)
        let out = text(c)
        let lower = out.lowercased()
        // adb exits 0 even when it fails to connect, so read what it says.
        guard lower.contains("connected to"), !lower.contains("failed"), !lower.contains("unable") else {
            return friendlyMessage(out)
        }
        let s = await run(["-s", serial, "get-state"], timeout: 10)
        if String(decoding: s.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "device" { return nil }
        return friendlyMessage(text(s))
    }

    // MARK: File operations

    static func test(serial: String) async -> String? {
        if let err = await connect(serial) { return err }
        let r = await shell(serial, "ls /sdcard/ >/dev/null")
        return r.ok ? nil : friendlyMessage(text(r))
    }

    static func list(_ dir: String, serial: String) async throws -> [RemoteEntry] {
        if let err = await connect(serial) { throw ADBError(err) }
        let r = await shell(serial, "ls -1Ap " + quote(androidPath(dir) + "/"))
        guard r.ok else { throw ADBError(friendlyMessage(text(r))) }
        var entries: [RemoteEntry] = []
        for raw in String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var name = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !name.isEmpty, name != "./", name != "../" else { continue }
            let isDir = name.hasSuffix("/")
            if isDir { name.removeLast() }
            entries.append(RemoteEntry(name: name, isDirectory: isDir, size: nil))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Size of a file on the TV, or nil if it isn't there (or the TV can't be reached).
    static func size(_ path: String, serial: String) async -> Int64? {
        guard await connect(serial) == nil else { return nil }
        return await statSize(androidPath(path), serial: serial)
    }

    fileprivate static func statSize(_ androidPath: String, serial: String) async -> Int64? {
        let r = await shell(serial, "stat -c %s " + quote(androidPath), timeout: 8)
        guard r.ok else { return nil }
        return Int64(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func makeDirectory(_ path: String, serial: String) async throws {
        if let err = await connect(serial) { throw ADBError(err) }
        let r = await shell(serial, "mkdir -p " + quote(androidPath(path)))
        guard r.ok else { throw ADBError(friendlyMessage(text(r))) }
    }

    /// One `adb push`. adb doesn't report progress when it isn't writing to a terminal,
    /// so the file's size on the TV is checked once a second instead.
    final class PushRun: TransferRun {
        private let local: URL, remotePath: String, total: Int64, serial: String
        private let progress: (Double) -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var process: ProcessRun?

        init(local: URL, remotePath: String, total: Int64, serial: String, progress: @escaping (Double) -> Void) {
            self.local = local; self.remotePath = remotePath; self.total = total
            self.serial = serial; self.progress = progress
        }

        private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// Keeps the push process so cancel() can stop it; false if already cancelled.
        private func attach(_ p: ProcessRun) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            process = p
            return true
        }

        func cancel() {
            lock.lock(); cancelled = true; let p = process; lock.unlock()
            p?.cancel()
        }

        func run() async -> CurlResult {
            func stopped() -> CurlResult { CurlResult(status: 1, stdout: Data(), stderr: "", cancelled: true) }
            if let err = await ADBClient.connect(serial) {
                return CurlResult(status: 1, stdout: Data(), stderr: err, cancelled: isCancelled)
            }
            let target = ADBClient.androidPath(remotePath)
            _ = await ADBClient.shell(serial, "mkdir -p " + ADBClient.quote((target as NSString).deletingLastPathComponent))
            guard let adb = ADBClient.locate() else {
                return CurlResult(status: -2, stdout: Data(), stderr: ADBClient.missingMessage, cancelled: false)
            }
            let p = ProcessRun(executable: adb, arguments: ["-s", serial, "push", local.path, target])
            guard attach(p) else { return stopped() }

            let (serial, total, progress) = (serial, total, progress)
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    if let n = await ADBClient.statSize(target, serial: serial), total > 0 {
                        progress(min(0.999, Double(n) / Double(total)))
                    }
                }
            }
            let r = await p.run()
            poller.cancel()
            if r.ok {
                // Ask Android to index the new file, so gallery and video apps see it straight away.
                let uri = "file://" + (target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)
                _ = await ADBClient.shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "
                                          + ADBClient.quote(uri) + " >/dev/null 2>&1", timeout: 10)
            }
            return r
        }
    }

    // MARK: Messages

    /// Turns what adb prints into something a person can act on.
    static func friendlyMessage(_ raw: String, fileSize: Int64? = nil) -> String {
        let t = raw.lowercased()
        if raw.contains(missingMessage) { return missingMessage }
        if t.contains("connection refused") {
            return "The TV refused the connection. Turn on Network debugging (or ADB debugging) in the TV's Developer options."
        }
        if t.contains("failed to authenticate") || t.contains("unauthorized") {
            return "Look at the TV: allow debugging from this Mac (tick \"Always allow from this computer\"), then try again."
        }
        if t.contains("timed out") || t.contains("no route") || t.contains("host is down")
            || t.contains("network is unreachable") || t.contains("cannot connect") {
            return "Can't reach the TV. Is it switched on, and on the same Wi-Fi as the Mac?"
        }
        if t.contains("offline") {
            return "The TV's debugging connection went offline. Try again; if it keeps happening, turn Network debugging off and on."
        }
        if t.contains("file too large") || (t.contains("no space") && (fileSize ?? 0) >= 4_294_967_296) {
            return "The TV refused the file. Files over 4 GB can't go onto a FAT32 USB drive — use internal storage instead, or check free space."
        }
        if t.contains("no space left") { return "The TV is out of space." }
        if t.contains("read-only file system") || t.contains("permission denied") {
            return "The TV won't let adb write to that folder. Pick a folder in internal storage."
        }
        if t.contains("no such file or directory") { return "That file or folder doesn't exist on the TV." }
        if t.contains("not found") { return "Lost the connection to the TV. Try again." }
        let last = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        let cleaned = last.replacingOccurrences(of: "adb: error: ", with: "").replacingOccurrences(of: "error: ", with: "")
        return cleaned.isEmpty ? "adb failed." : cleaned
    }
}
