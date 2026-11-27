import Foundation

/// Connection details for the FTP server that File Manager+ runs on the TV
/// ("Access from network" → Start service).
struct FTPConfig: Equatable {
    var host: String
    var port: Int
    var user: String
    var password: String

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isComplete: Bool { !trimmedHost.isEmpty && port > 0 && port < 65536 }
    var display: String { "\(trimmedHost):\(port)" }

    /// Builds an ftp:// URL. Every path component is percent-encoded so names with
    /// spaces, brackets, accents, emoji etc. reach the server byte-for-byte as UTF-8.
    func url(_ remotePath: String, directory: Bool = false) -> String {
        let comps = remotePath.split(separator: "/").map { FTPConfig.encode(String($0)) }
        var s = "ftp://\(trimmedHost):\(port)/" + comps.joined(separator: "/")
        if directory && !comps.isEmpty { s += "/" }
        return s
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    /// Credentials go to curl on stdin (`-K -`), never on the command line,
    /// so they don't show up in `ps`.
    var curlConfigText: String {
        func q(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let u = user.trimmingCharacters(in: .whitespaces).isEmpty ? "anonymous" : user
        return "user = \"\(q(u)):\(q(password))\"\n"
    }
}

struct CurlResult {
    var status: Int32
    var stdout: Data
    var stderr: String
    var cancelled: Bool
    var ok: Bool { status == 0 && !cancelled }
}

/// Something sending a file that can be stopped part-way (curl for FTP, adb for network debugging).
protocol TransferRun: AnyObject {
    func run() async -> CurlResult
    func cancel()
}

typealias CurlRun = ProcessRun

extension ProcessRun {
    /// One run of /usr/bin/curl. Credentials go in on stdin as a curl config.
    convenience init(arguments: [String], config: FTPConfig) {
        self.init(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                  arguments: ["-K", "-", "--connect-timeout", "8"] + arguments,
                  stdin: Data(config.curlConfigText.utf8))
    }
}

/// One run of a command-line tool. Keeps a handle on the process so it can be cancelled.
final class ProcessRun: TransferRun {
    private let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var wasCancelled = false
    private let stdinData: Data
    /// Called (on a background queue) with each chunk the tool writes to stderr — used for the progress bar.
    var onStderr: ((String) -> Void)?

    init(executable: URL, arguments: [String], stdin: Data = Data()) {
        process.executableURL = executable
        process.arguments = arguments
        stdinData = stdin
    }

    func run() async -> CurlResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CurlResult, Never>) in
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.lock(); self.out.append(d); self.lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.lock(); self.err.append(d); self.lock.unlock()
                if let s = String(data: d, encoding: .utf8) { self.onStderr?(s) }
            }
            process.terminationHandler = { [weak self] p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                guard let self else {
                    cont.resume(returning: CurlResult(status: p.terminationStatus, stdout: restOut, stderr: "", cancelled: true))
                    return
                }
                self.lock.lock()
                self.out.append(restOut); self.err.append(restErr)
                let result = CurlResult(status: p.terminationStatus,
                                        stdout: self.out,
                                        stderr: String(decoding: self.err, as: UTF8.self),
                                        cancelled: self.wasCancelled)
                self.lock.unlock()
                cont.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                cont.resume(returning: CurlResult(status: -1, stdout: Data(), stderr: error.localizedDescription, cancelled: false))
                return
            }
            if !stdinData.isEmpty { inPipe.fileHandleForWriting.write(stdinData) }
            try? inPipe.fileHandleForWriting.close()
        }
    }

    func cancel() {
        lock.lock(); wasCancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

struct RemoteEntry: Identifiable, Hashable {
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var id: String { (isDirectory ? "d:" : "f:") + name }
}

enum FTPError: LocalizedError {
    case curl(Int32, String)
    var errorDescription: String? {
        switch self { case let .curl(code, raw): return FTPClient.friendlyMessage(code: code, raw: raw) }
    }
}

enum FTPClient {
    /// Turns curl exit codes into something a person can act on.
    static func friendlyMessage(code: Int32, raw: String, fileSize: Int64? = nil) -> String {
        let detail = raw.split(whereSeparator: \.isNewline).last(where: { $0.contains("curl:") }).map(String.init) ?? ""
        switch code {
        case 6: return "Can't resolve the TV's address. Check the IP."
        case 7: return "Can't reach the TV. Is \"Access from network\" started on the TV, and is the Mac on the same Wi-Fi?"
        case 28: return "The TV stopped responding (timed out)."
        case 67: return "The TV refused the login. Check the password (and username) shown on the TV."
        case 9: return "The TV refused access to that folder."
        case 19, 78: return "That file or folder doesn't exist on the TV."
        case 25:
            if let s = fileSize, s >= 4_294_967_296 {
                return "The TV refused the file. Files over 4 GB can't go onto a FAT32 USB drive — send it to internal storage instead, or check free space."
            }
            return "The TV refused the upload — it may be out of space or the folder is read-only."
        case 55, 56: return "The connection dropped mid-transfer. Press Retry to resume where it stopped."
        case 15: return "Couldn't open a data connection to the TV (passive mode failed)."
        case -1: return "Couldn't launch curl: \(raw)"
        default: return detail.isEmpty ? "Transfer failed (curl error \(code))." : detail
        }
    }

    /// Lists a remote directory. Parses both Unix-style and DOS-style LIST output.
    static func list(_ dir: String, config: FTPConfig) async throws -> [RemoteEntry] {
        let run = CurlRun(arguments: ["-sS", "-Q", "*OPTS UTF8 ON", config.url(dir, directory: true)], config: config)
        let r = await run.run()
        guard r.ok else { throw FTPError.curl(r.status, r.stderr) }
        let text = String(decoding: r.stdout, as: UTF8.self)
        var entries: [RemoteEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let e = parseListLine(line), e.name != ".", e.name != ".." { entries.append(e) }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func parseListLine(_ line: String) -> RemoteEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        // Unix: drwxr-xr-x 1 owner group 4096 Nov 26 16:52 Name with spaces
        if let first = parts.first, let c = first.first, "dl-".contains(c), first.count >= 10, parts.count >= 9 {
            // Find the name by skipping 8 whitespace-separated fields in the original string.
            var idx = line.startIndex
            var fields = 0
            while fields < 8 && idx < line.endIndex {
                while idx < line.endIndex && line[idx] == " " { idx = line.index(after: idx) }
                while idx < line.endIndex && line[idx] != " " { idx = line.index(after: idx) }
                fields += 1
            }
            while idx < line.endIndex && line[idx] == " " { idx = line.index(after: idx) }
            var name = String(line[idx...])
            if c == "l", let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
            guard !name.isEmpty else { return nil }
            return RemoteEntry(name: name, isDirectory: c == "d" || c == "l", size: Int64(parts[4]))
        }
        // DOS: 11-26-26  04:52PM       <DIR>          Name
        if parts.count >= 4, parts[0].contains("-"), parts[1].contains(":") {
            let isDir = parts[2] == "<DIR>"
            guard let r = line.range(of: String(parts[2])) else { return nil }
            let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return RemoteEntry(name: name, isDirectory: isDir, size: isDir ? nil : Int64(parts[2]))
        }
        // Bare name list fallback
        return RemoteEntry(name: line.trimmingCharacters(in: .whitespaces), isDirectory: false, size: nil)
    }

    /// Size of a remote file, or nil if it doesn't exist.
    static func size(_ path: String, config: FTPConfig) async -> Int64? {
        let run = CurlRun(arguments: ["-sS", "-Q", "*OPTS UTF8 ON", "-I", config.url(path)], config: config)
        let r = await run.run()
        guard r.ok else { return nil }
        let text = String(decoding: r.stdout, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                return Int64(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Checks we can log in and list the root.
    static func test(config: FTPConfig) async -> String? {
        do { _ = try await list("/", config: config); return nil }
        catch { return error.localizedDescription }
    }

    static func makeDirectory(_ path: String, config: FTPConfig) async throws {
        let run = CurlRun(arguments: ["-sS", "-Q", "*OPTS UTF8 ON", "-Q", "MKD /" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                      "--list-only", config.url("/", directory: true)], config: config)
        let r = await run.run()
        guard r.ok else { throw FTPError.curl(r.status, r.stderr) }
    }

    /// Starts an upload. Progress (0...1 of the bytes this run sends) is reported via `progress`.
    static func makeUpload(local: URL, remotePath: String, resumeFrom: Int64, config: FTPConfig,
                           progress: @escaping (Double) -> Void) -> ProcessRun {
        var args = ["-#", "-S", "--ftp-create-dirs", "-Q", "*OPTS UTF8 ON", "-T", local.path]
        if resumeFrom > 0 { args += ["-C", String(resumeFrom)] }
        // Test hook (end-to-end tests slow uploads down so they can interrupt one part-way).
        let env = ProcessInfo.processInfo.environment
        if env["TVFERRY_DEBUG"] == "1", let rate = env["TVFERRY_LIMIT_RATE"], !rate.isEmpty { args += ["--limit-rate", rate] }
        args.append(config.url(remotePath))
        let run = CurlRun(arguments: args, config: config)
        // curl's progress bar writes "\r####   42.7%" repeatedly.
        let regex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d)?)%"#)
        run.onStderr = { chunk in
            let ns = chunk as NSString
            let matches = regex.matches(in: chunk, range: NSRange(location: 0, length: ns.length))
            if let m = matches.last {
                let v = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")
                if let pct = Double(v) { progress(min(1, pct / 100)) }
            }
        }
        return run
    }
}
