import Foundation

public enum TranscriptionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whisper on this Mac; the transcript is attached through finalise.
    case local
    /// Hear Me Out's cloud pipeline transcribes the uploaded audio.
    case cloud
    /// Audio only (`transcribe:false`, no transcript).
    case none

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: return "On this Mac"
        case .cloud: return "Hear Me Out cloud"
        case .none: return "No transcript"
        }
    }

    public var explanation: String {
        switch self {
        case .local: return "Whisper runs privately on your Mac. Only the finished transcript is sent to Hear Me Out."
        case .cloud: return "Hear Me Out's cloud service transcribes the uploaded audio."
        case .none: return "The audio is uploaded and shared without a transcript."
        }
    }
}

public enum TitleProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case appleIntelligence
    case openAI
    case hearMeOut
    case manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .hearMeOut: return "Hear Me Out cloud"
        case .manual: return "I'll write my own"
        }
    }

    public var explanation: String {
        switch self {
        case .appleIntelligence: return "Generated on this Mac. Nothing leaves your computer."
        case .openAI: return "Only the transcript is sent to OpenAI, using your own API key."
        case .hearMeOut: return "Hear Me Out titles the recording from its transcript."
        case .manual: return "No automatic titles. Type one, or keep the date-based name."
        }
    }

    /// Providers whose title is produced by this app (and sent with `titleIsAi:true`).
    public var isGeneratedByApp: Bool { self == .appleIntelligence || self == .openAI }
}

/// Per-account processing choices, snapshotted onto each recording when it is saved.
public struct ProcessingPreferences: Codable, Equatable, Sendable {
    public var transcription: TranscriptionMode
    public var titleProvider: TitleProvider

    public init(transcription: TranscriptionMode = .local, titleProvider: TitleProvider = .hearMeOut) {
        self.transcription = transcription
        self.titleProvider = titleProvider
    }

    /// Plain-English summary of what leaves the Mac.
    public var privacySummary: String {
        var parts: [String] = ["Audio is uploaded to your Hear Me Out storage."]
        switch transcription {
        case .local: parts.append("Transcription happens on this Mac.")
        case .cloud: parts.append("Hear Me Out transcribes it in the cloud.")
        case .none: parts.append("No transcript is made.")
        }
        if transcription != .none {
            switch titleProvider {
            case .appleIntelligence: parts.append("The title is written on this Mac.")
            case .openAI: parts.append("The transcript is sent to OpenAI to write a title.")
            case .hearMeOut: parts.append("Hear Me Out writes the title.")
            case .manual: parts.append("You choose the title.")
            }
        }
        return parts.joined(separator: " ")
    }
}

public enum AuthMethod: String, Codable, Sendable {
    /// Signed in with Google through the native PKCE flow; holds a per-Mac `hmo_` key.
    case google
    /// Connected by pasting an API key from Settings → API keys.
    case apiKey
}

/// A connected Hear Me Out account. Secrets live in the Keychain, never here.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    /// The Hear Me Out user id when known; otherwise a local identifier.
    public var id: String
    public var userId: String?
    public var email: String?
    public var displayName: String?
    public var avatarURL: String?
    /// Optional label such as "Work" or "Tutoring".
    public var nickname: String?
    public var authMethod: AuthMethod
    public var keyPrefix: String?
    public var themeId: String
    public var preferences: ProcessingPreferences
    public var needsReconnect: Bool
    public var addedAt: Date

    public init(id: String, userId: String?, email: String?, displayName: String?, avatarURL: String?, nickname: String? = nil,
                authMethod: AuthMethod, keyPrefix: String?, themeId: String, preferences: ProcessingPreferences = .init(),
                needsReconnect: Bool = false, addedAt: Date = Date()) {
        self.id = id
        self.userId = userId
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.nickname = nickname
        self.authMethod = authMethod
        self.keyPrefix = keyPrefix
        self.themeId = themeId
        self.preferences = preferences
        self.needsReconnect = needsReconnect
        self.addedAt = addedAt
    }

    /// The best name to show: nickname, Google name, email, then key prefix.
    public var title: String {
        if let n = nickname?.trimmed, !n.isEmpty { return n }
        if let n = displayName?.trimmed, !n.isEmpty { return n }
        if let e = email, !e.isEmpty { return e }
        return "Account \(keyPrefix ?? String(id.prefix(6)))"
    }

    /// One or two initials for the fallback avatar.
    public var initials: String {
        let source = displayName?.trimmed.nonEmpty ?? nickname?.trimmed.nonEmpty ?? email ?? "?"
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" }).filter { !$0.isEmpty }
        let letters = words.prefix(source.contains("@") ? 1 : 2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nonEmpty: String? { isEmpty ? nil : self }
}
