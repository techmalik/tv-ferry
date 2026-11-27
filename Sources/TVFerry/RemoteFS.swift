import Foundation

/// How TV Ferry reaches the TV.
enum TransportKind: String, CaseIterable, Identifiable {
    /// File Manager+'s "Access from network" FTP server (or any FTP server).
    case ftp
    /// Android's network debugging (adb). Works whenever the TV is on; no app has to be running.
    case adb
    var id: String { rawValue }
    var label: String { self == .ftp ? "File Manager+ (FTP)" : "Network debugging (ADB)" }
    var defaultPort: Int { self == .ftp ? 8782 : 5555 }
}

/// Everything needed to reach one TV, whichever way.
struct Remote: Equatable {
    var kind: TransportKind
    var ftp: FTPConfig
    var adbPort: Int

    var host: String { ftp.trimmedHost }
    var port: Int { kind == .ftp ? ftp.port : adbPort }
    var isComplete: Bool { !host.isEmpty && (1..<65536).contains(port) }
    var display: String { "\(host):\(port)" }
    /// Identifies this TV and transport (used to remember unfinished uploads).
    var identity: String { "\(kind.rawValue)://\(host.lowercased()):\(port)" }
    /// The device name adb uses for a network connection.
    var adbSerial: String { "\(host):\(adbPort)" }
}

/// The file operations TV Ferry needs, sent to whichever transport the TV uses.
/// Paths are always TV Ferry's own ("/Movies/Film.mkv"); for adb they live under the TV's internal storage.
enum RemoteFS {
    static func list(_ dir: String, on r: Remote) async throws -> [RemoteEntry] {
        switch r.kind {
        case .ftp: return try await FTPClient.list(dir, config: r.ftp)
        case .adb: return try await ADBClient.list(dir, serial: r.adbSerial)
        }
    }

    static func size(_ path: String, on r: Remote) async -> Int64? {
        switch r.kind {
        case .ftp: return await FTPClient.size(path, config: r.ftp)
        case .adb: return await ADBClient.size(path, serial: r.adbSerial)
        }
    }

    static func makeDirectory(_ path: String, on r: Remote) async throws {
        switch r.kind {
        case .ftp: try await FTPClient.makeDirectory(path, config: r.ftp)
        case .adb: try await ADBClient.makeDirectory(path, serial: r.adbSerial)
        }
    }

    /// nil when the TV answers and lets us in; otherwise what to do about it.
    static func test(_ r: Remote) async -> String? {
        switch r.kind {
        case .ftp: return await FTPClient.test(config: r.ftp)
        case .adb: return await ADBClient.test(serial: r.adbSerial)
        }
    }

    /// FTP can carry on from a byte offset; adb push always sends the whole file.
    static func supportsResume(_ r: Remote) -> Bool { r.kind == .ftp }

    /// `progress` gets 0...1 of the whole file.
    static func makeUpload(local: URL, remotePath: String, resumeFrom: Int64, size: Int64, on r: Remote,
                           progress: @escaping (Double) -> Void) -> TransferRun {
        switch r.kind {
        case .ftp:
            return FTPClient.makeUpload(local: local, remotePath: remotePath, resumeFrom: resumeFrom,
                                        config: r.ftp, progress: progress)
        case .adb:
            return ADBClient.PushRun(local: local, remotePath: remotePath, total: size,
                                     serial: r.adbSerial, progress: progress)
        }
    }

    static func friendlyMessage(_ result: CurlResult, on r: Remote, fileSize: Int64?) -> String {
        switch r.kind {
        case .ftp: return FTPClient.friendlyMessage(code: result.status, raw: result.stderr, fileSize: fileSize)
        case .adb: return ADBClient.friendlyMessage(String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr,
                                                   fileSize: fileSize)
        }
    }
}
