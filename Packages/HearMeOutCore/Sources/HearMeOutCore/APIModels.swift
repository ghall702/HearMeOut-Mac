import Foundation

// MARK: - Lenient numeric decoding (Postgres numeric/bigint can arrive as numbers or strings)

@propertyWrapper
public struct LenientDouble: Codable, Equatable, Sendable {
    public var wrappedValue: Double?
    public init(wrappedValue: Double?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let d = try? c.decode(Double.self) { wrappedValue = d }
        else if let s = try? c.decode(String.self) { wrappedValue = Double(s) }
        else { wrappedValue = nil }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: LenientDouble.Type, forKey key: Key) throws -> LenientDouble {
        try decodeIfPresent(type, forKey: key) ?? LenientDouble(wrappedValue: nil)
    }
}

// MARK: - Recordings

/// A recording as returned by GET /recordings (list) or GET /recordings/:id (full row).
public struct RemoteRecording: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    @LenientDouble public var duration_seconds: Double?
    @LenientDouble public var size_bytes: Double?
    public var status: String?
    public var transcription_status: String?
    public var transcription_error: String?
    public var share_enabled: Bool?
    @LenientDouble public var play_count: Double?
    public var first_played_at: String?
    public var last_played_at: String?
    public var created_at: String?
    public var recorded_at: String?
    public var title_is_ai: Bool?
    public var source: String?
    public var mime_type: String?
    public var original_filename: String?
    public var transcript: String?
    public var shareUrl: String?
    public var embedUrl: String?
    public var embedCode: String?

    public init(id: String, title: String, duration: Double? = nil, status: String? = "ready",
                transcriptionStatus: String? = nil, shareEnabled: Bool? = true, playCount: Double? = 0,
                createdAt: String? = nil, recordedAt: String? = nil, shareUrl: String? = nil,
                embedUrl: String? = nil, embedCode: String? = nil, transcript: String? = nil) {
        self.id = id
        self.title = title
        self.duration_seconds = duration
        self.status = status
        self.transcription_status = transcriptionStatus
        self.share_enabled = shareEnabled
        self.play_count = playCount
        self.created_at = createdAt
        self.recorded_at = recordedAt
        self.shareUrl = shareUrl
        self.embedUrl = embedUrl
        self.embedCode = embedCode
        self.transcript = transcript
    }

    public var recordedDate: Date? { ISODate.parse(recorded_at) ?? ISODate.parse(created_at) }
    public var plays: Int { Int(play_count ?? 0) }
    public var isReady: Bool { status == "ready" }
    public var hasTranscript: Bool { transcription_status == "done" }
    public var isShareable: Bool { isReady && (share_enabled ?? true) && shareUrl != nil }
}

public struct RecordingList: Codable, Sendable {
    public var items: [RemoteRecording]
}

// MARK: - Upload tickets

/// Response of POST /uploads (201) and POST /recordings/:id/upload-url, normalised.
public struct UploadTicket: Codable, Equatable, Sendable {
    public var recordingId: String
    public var key: String?
    public var uploadURL: URL
    public var method: String
    public var headers: [String: String]
    /// Unix seconds.
    public var exp: TimeInterval

    public init(recordingId: String, key: String?, uploadURL: URL, method: String = "PUT", headers: [String: String], exp: TimeInterval) {
        self.recordingId = recordingId
        self.key = key
        self.uploadURL = uploadURL
        self.method = method
        self.headers = headers
        self.exp = exp
    }

    /// True when the ticket expires within `margin` seconds (default 2 minutes).
    public func isExpiring(now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        exp - margin < now.timeIntervalSince1970
    }
}

/// Raw wire shapes: /uploads returns `url` + `token`; upload-url returns `uploadUrl` + `headers`.
struct RawUploadTicket: Decodable {
    var recordingId: String
    var key: String?
    var url: String?
    var uploadUrl: String?
    var token: String?
    var exp: TimeInterval?
    var method: String?
    var headers: [String: String]?

    func normalised() throws -> UploadTicket {
        guard let s = uploadUrl ?? url, let u = URL(string: s) else { throw HMOError.badResponse("upload ticket without URL") }
        var h = headers ?? [:]
        if h["Authorization"] == nil, let token { h["Authorization"] = "Bearer \(token)" }
        guard h["Authorization"] != nil else { throw HMOError.badResponse("upload ticket without authorisation") }
        return UploadTicket(recordingId: recordingId, key: key, uploadURL: u, method: method ?? "PUT", headers: h,
                            exp: exp ?? Date().addingTimeInterval(3600).timeIntervalSince1970)
    }
}

public struct CreateUploadRequest: Codable, Equatable, Sendable {
    public var ext: String
    public var size: Int64
    public var durationSeconds: Double?
    public var filename: String?
    public var mime: String?
    public var title: String?
    public var recordedAt: String?

    public init(ext: String, size: Int64, durationSeconds: Double?, filename: String?, mime: String?, title: String?, recordedAt: String?) {
        self.ext = ext
        self.size = size
        self.durationSeconds = durationSeconds
        self.filename = filename
        self.mime = mime
        self.title = title
        self.recordedAt = recordedAt
    }
}

// MARK: - Finalise

/// Body of POST /recordings/:id/finalize. Nil fields are omitted, so a missing title stays missing.
public struct FinalizeRequest: Codable, Equatable, Sendable {
    public var title: String?
    public var titleIsAi: Bool?
    public var transcript: String?
    public var transcribe: Bool?
    public var recordedAt: String?

    public init(title: String? = nil, titleIsAi: Bool? = nil, transcript: String? = nil, transcribe: Bool? = nil, recordedAt: String? = nil) {
        self.title = title
        self.titleIsAi = titleIsAi
        self.transcript = transcript
        self.transcribe = transcribe
        self.recordedAt = recordedAt
    }

    /// True when the call would only re-confirm the recording without sending anything new.
    public var carriesNothing: Bool { title == nil && transcript == nil && transcribe != true && recordedAt == nil }
}

public struct FinalizeResponse: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var title_is_ai: Bool?
    public var recorded_at: String?
    public var transcription_status: String?
    public var shareUrl: String
    public var embedUrl: String
    public var embedCode: String
}

public struct ShareLinks: Codable, Equatable, Sendable {
    public var shareUrl: String
    public var embedUrl: String
    public var embedCode: String

    public init(shareUrl: String, embedUrl: String, embedCode: String) {
        self.shareUrl = shareUrl
        self.embedUrl = embedUrl
        self.embedCode = embedCode
    }
}

// MARK: - Accounts

/// Profile returned by the native sign-in exchange, the extension exchange or GET /me.
public struct RemoteUser: Codable, Equatable, Sendable {
    public var id: String
    public var email: String?
    public var name: String?
    public var avatar_url: String?

    public init(id: String, email: String?, name: String?, avatar_url: String?) {
        self.id = id
        self.email = email
        self.name = name
        self.avatar_url = avatar_url
    }
}

public struct TokenExchangeResponse: Codable, Sendable {
    public var api_key: String
    public var user: RemoteUser
}

public struct MeResponse: Codable, Sendable {
    public var user: RemoteUser
    /// Optional server capabilities, e.g. ["native-auth", "playback"].
    public var features: [String]?
}

public struct PlaybackResponse: Codable, Sendable {
    public var url: String
    public var exp: TimeInterval?
}

struct ErrorBody: Decodable {
    var error: String?
}
