import Foundation

/// Small, crash-safe JSON persistence: atomic writes, owner-only permissions, and a backup of the
/// previous version so one corrupt write can never lose the queue.
public struct JSONStore<Value: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        return d
    }

    public var backupURL: URL { url.appendingPathExtension("bak") }

    public func load() -> Value? {
        for candidate in [url, backupURL] {
            if let data = try? Data(contentsOf: candidate), let v = try? Self.decoder.decode(Value.self, from: data) { return v }
        }
        return nil
    }

    public func save(_ value: Value) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(value)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }
}
