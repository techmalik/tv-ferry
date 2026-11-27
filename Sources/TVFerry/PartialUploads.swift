import Foundation

/// Remembers uploads TV Ferry started but didn't finish, so a retry only resumes a partial
/// file that TV Ferry itself wrote from this exact Mac file. Without this, a smaller file
/// that happens to have the same name on the TV (an older copy, a different movie) would get
/// the rest of the new file appended to it, ending up corrupt while its size looked right.
@MainActor
enum PartialUploads {
    struct Entry: Codable, Equatable {
        var localPath: String
        var size: Int64
        var modified: Double
        var started: Date
    }

    /// Entries older than this are forgotten; the partial file on the TV is then sent again from the start.
    private static let maxAge: TimeInterval = 30 * 24 * 3600

    static var fileURL: URL {
        let dir: URL
        if let o = ProcessInfo.processInfo.environment["TVFERRY_STATE_DIR"], !o.isEmpty {
            dir = URL(fileURLWithPath: o, isDirectory: true)   // used by the end-to-end tests
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TV Ferry", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("partial-uploads.json")
    }

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        return all.filter { $0.value.started > cutoff }
    }

    private static func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func key(_ remote: Remote, _ remotePath: String) -> String { remote.identity + remotePath }

    private static func describe(_ local: URL, size: Int64) -> Entry? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Entry(localPath: local.standardizedFileURL.path, size: size,
                     modified: modified.timeIntervalSince1970, started: Date())
    }

    /// True when the file at `remotePath` is a partial copy TV Ferry wrote from this same,
    /// unchanged Mac file, so it's safe to carry on from where it stopped.
    static func canResume(_ config: Remote, remotePath: String, local: URL, size: Int64) -> Bool {
        guard let saved = load()[key(config, remotePath)], let now = describe(local, size: size) else { return false }
        return saved.localPath == now.localPath && saved.size == now.size && saved.modified == now.modified
    }

    /// Call just before sending bytes. Keeps the original start time when resuming.
    static func begin(_ config: Remote, remotePath: String, local: URL, size: Int64) {
        guard var entry = describe(local, size: size) else { return }
        var all = load()
        let k = key(config, remotePath)
        if let old = all[k], old.localPath == entry.localPath, old.size == entry.size, old.modified == entry.modified {
            entry.started = old.started
        }
        all[k] = entry
        save(all)
    }

    /// Call once the file on the TV is complete (sent, or already there).
    static func finish(_ config: Remote, remotePath: String) {
        var all = load()
        guard all.removeValue(forKey: key(config, remotePath)) != nil else { return }
        save(all)
    }
}
