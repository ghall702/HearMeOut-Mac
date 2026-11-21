import Foundation
import AppKit
import Security
import Network
import os
import HearMeOutCore

let appLog = Logger(subsystem: "uk.george-hall.hearmeout", category: "app")

/// Where everything lives (inside the app's sandbox container). Folders are owner-only (0700).
enum AppPaths {
    static var demoRoot: URL?

    static var root: URL {
        if let d = demoRoot { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hear Me Out", isDirectory: true)
    }
    static var audio: URL { ensure(root.appendingPathComponent("Audio", isDirectory: true)) }
    static var avatars: URL { ensure(root.appendingPathComponent("Avatars", isDirectory: true)) }
    static var libraryCache: URL { ensure(root.appendingPathComponent("Library", isDirectory: true)) }
    static var models: URL { ensure(root.appendingPathComponent("WhisperModels", isDirectory: true)) }
    static var queueFile: URL { ensure(root).appendingPathComponent("queue.json") }
    static var accountsFile: URL { ensure(root).appendingPathComponent("accounts.json") }
    static var settingsFile: URL { ensure(root).appendingPathComponent("settings.json") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return url
    }

    static func protect(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}

/// Generic-password Keychain storage. Values are never logged.
enum Keychain {
    static let service = "uk.george-hall.hearmeout"

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Hear Me Out"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    static func apiKeyAccount(_ accountId: String) -> String { "hmo-key:\(accountId)" }
    static let openAIAccount = "openai-api-key"
}

/// Writes share formats to the pasteboard (HTML and plain text together for Gmail).
enum Clipboard {
    static func copy(_ payload: ClipboardPayload) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let html = payload.html {
            pb.declareTypes([.html, .string], owner: nil)
            pb.setString(html, forType: .html)
        }
        pb.setString(payload.plainText, forType: .string)
    }

    static func copy(_ format: ShareFormat, links: ShareLinks) {
        copy(ShareText.payload(format, links: links))
    }
}

/// Watches connectivity so the queue pauses network work offline and resumes immediately when back.
@MainActor
final class Connectivity: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "hmo.connectivity"))
    }
}

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Double {
    /// "3:07" or "1:02:03".
    var clockText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let s = Int(self.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Date {
    var friendlyText: String {
        let cal = Calendar.current
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_GB")
        tf.dateFormat = "HH:mm"
        let time = tf.string(from: self)
        if cal.isDateInToday(self) { return "Today, \(time)" }
        if cal.isDateInYesterday(self) { return "Yesterday, \(time)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = cal.isDate(self, equalTo: Date(), toGranularity: .year) ? "EEE d MMM, HH:mm" : "d MMM yyyy, HH:mm"
        return f.string(from: self)
    }
}
