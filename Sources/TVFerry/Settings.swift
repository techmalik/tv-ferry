import Foundation
import Security

/// Saved TV connection. Password lives in the Keychain; everything else in UserDefaults.
final class ConnectionSettings: ObservableObject {
    private let d = UserDefaults.standard
    private var persist = true

    @Published var host: String { didSet { if persist { d.set(host, forKey: "host") } } }
    @Published var port: Int { didSet { if persist { d.set(port, forKey: "port") } } }
    @Published var user: String { didSet { if persist { d.set(user, forKey: "user") } } }
    @Published var password: String { didSet { if persist { Keychain.set(password, account: "tv") } } }
    @Published var remoteFolder: String { didSet { if persist { d.set(remoteFolder, forKey: "remoteFolder") } } }
    @Published var skipExisting: Bool { didSet { if persist { d.set(skipExisting, forKey: "skipExisting") } } }
    @Published var kind: TransportKind { didSet { if persist { d.set(kind.rawValue, forKey: "transport") } } }
    @Published var adbPort: Int { didSet { if persist { d.set(adbPort, forKey: "adbPort") } } }
    /// What the user calls the TV ("Living Room TV"). Optional.
    @Published var tvName: String { didSet { if persist { d.set(tvName, forKey: "tvName") } } }
    /// Folders on the TV chosen recently, newest first (shown in the sidebar).
    @Published var recentFolders: [String] { didSet { if persist { d.set(recentFolders, forKey: "recentFolders") } } }

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        port = d.object(forKey: "port") != nil ? d.integer(forKey: "port") : 8782
        user = d.string(forKey: "user") ?? ""
        // Test hook: TVFERRY_DEBUG=1 TVFERRY_NO_KEYCHAIN=1 keeps screenshot and test runs out of the Keychain.
        let env = ProcessInfo.processInfo.environment
        let skipKeychain = env["TVFERRY_DEBUG"] == "1" && env["TVFERRY_NO_KEYCHAIN"] == "1"
        password = skipKeychain ? "" : (Keychain.get(account: "tv") ?? "")
        remoteFolder = d.string(forKey: "remoteFolder") ?? "/Movies"
        skipExisting = d.object(forKey: "skipExisting") as? Bool ?? true
        kind = d.string(forKey: "transport").flatMap(TransportKind.init(rawValue:)) ?? .ftp
        adbPort = d.object(forKey: "adbPort") != nil ? d.integer(forKey: "adbPort") : TransportKind.adb.defaultPort
        tvName = d.string(forKey: "tvName") ?? ""
        recentFolders = d.stringArray(forKey: "recentFolders") ?? [d.string(forKey: "remoteFolder") ?? "/Movies"]
    }

    /// In-memory only (used by the command-line self test).
    init(ephemeral c: FTPConfig, folder: String, kind: TransportKind = .ftp) {
        persist = false
        host = c.host; port = c.port; user = c.user; password = c.password
        remoteFolder = folder; skipExisting = true
        self.kind = kind; adbPort = c.port
        tvName = ""; recentFolders = [folder]
    }

    var config: FTPConfig { FTPConfig(host: host, port: port, user: user, password: password) }
    /// The TV, reached the way the user chose.
    var remote: Remote { Remote(kind: kind, ftp: config, adbPort: adbPort) }

    var displayName: String {
        let n = tvName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return host.isEmpty ? "No TV set up" : host
    }

    /// Sends files to `folder` from now on, and keeps it near the top of the sidebar.
    func choose(folder: String) {
        remoteFolder = folder
        recentFolders = Array(([folder] + recentFolders.filter { $0 != folder }).prefix(5))
    }

    /// "Movies" for /Movies, "Internal storage" for the top level.
    static func folderTitle(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? "Internal storage" : last
    }
}

enum Keychain {
    private static let service = "TV Ferry"

    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
