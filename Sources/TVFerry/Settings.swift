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

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        port = d.object(forKey: "port") as? Int ?? 8782
        user = d.string(forKey: "user") ?? ""
        password = Keychain.get(account: "tv") ?? ""
        remoteFolder = d.string(forKey: "remoteFolder") ?? "/Movies"
        skipExisting = d.object(forKey: "skipExisting") as? Bool ?? true
    }

    /// In-memory only (used by the command-line self test).
    init(ephemeral c: FTPConfig, folder: String) {
        persist = false
        host = c.host; port = c.port; user = c.user; password = c.password
        remoteFolder = folder; skipExisting = true
    }

    var config: FTPConfig { FTPConfig(host: host, port: port, user: user, password: password) }
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
