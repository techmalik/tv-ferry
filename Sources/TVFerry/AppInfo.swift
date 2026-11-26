import Foundation

/// Everything that identifies the app and its author. Change the URLs here if you fork it.
enum AppInfo {
    static let name = "TV Ferry"
    static let tagline = "Drag movies from your Mac onto your Android TV."
    static let summary = "TV Ferry sends files and folders from your Mac to File Manager+ on your Android TV over your Wi-Fi. It fixes file names Android can't take, skips macOS clutter, and picks up interrupted transfers where they stopped."
    static let author = "Malik Kabir"
    static let email = "techmaleek@gmail.com"
    static let license = "MIT License"
    static let year = "2026"

    static let repo = URL(string: "https://github.com/techmalik/tv-ferry")!
    static let issues = URL(string: "https://github.com/techmalik/tv-ferry/issues")!
    static let releases = URL(string: "https://github.com/techmalik/tv-ferry/releases")!

    /// Where in-app feedback is delivered (an email-forwarding form service; no account or server needed).
    static var feedbackEndpoint: URL {
        // Test hook: only honored when TVFERRY_DEBUG=1 is set in the environment.
        if ProcessInfo.processInfo.environment["TVFERRY_DEBUG"] == "1",
           let o = UserDefaults.standard.string(forKey: "feedbackEndpointOverride"), let u = URL(string: o) { return u }
        return URL(string: "https://formsubmit.co/\(email)")!
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// A pre-filled email draft (nothing is sent until the user presses Send in their mail app).
    static var feedbackURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = "\n\n—\nTV Ferry \(version) (\(build)) · macOS \(os)"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [
            URLQueryItem(name: "subject", value: "TV Ferry feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url ?? URL(string: "mailto:\(email)")!
    }
}

/// App-level preferences (TV connection settings live in ConnectionSettings).
enum Prefs {
    private static let d = UserDefaults.standard
    static var autoCheckUpdates: Bool { get { d.bool(forKey: "autoCheckUpdates") } set { d.set(newValue, forKey: "autoCheckUpdates") } }
    static var lastUpdateCheck: Date? { get { d.object(forKey: "lastUpdateCheck") as? Date } set { d.set(newValue, forKey: "lastUpdateCheck") } }
    static var skippedVersion: String? { get { d.string(forKey: "skippedVersion") } set { d.set(newValue, forKey: "skippedVersion") } }
}

/// Lets the menu's checkbox reflect and change the auto-update preference.
final class UpdatePrefs: ObservableObject {
    static let shared = UpdatePrefs()
    @Published var autoCheck: Bool = Prefs.autoCheckUpdates {
        didSet {
            Prefs.autoCheckUpdates = autoCheck
            Task { @MainActor in Updates.checkIfDue() }
        }
    }
}
