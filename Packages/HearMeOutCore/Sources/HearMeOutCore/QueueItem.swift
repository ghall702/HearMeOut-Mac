import Foundation

public enum UploadStage: String, Codable, Sendable, Comparable {
    /// Saved locally; no recording exists on the server yet.
    case pending
    /// POST /uploads succeeded: a recording id and an upload ticket are stored.
    case ticketed
    /// The media server accepted the bytes.
    case uploaded
    /// Finalised: the server confirmed the file and returned share links.
    case ready

    private var order: Int { [.pending: 0, .ticketed: 1, .uploaded: 2, .ready: 3][self] ?? 0 }
    public static func < (a: UploadStage, b: UploadStage) -> Bool { a.order < b.order }
}

public enum TrackStage: String, Codable, Sendable {
    case notNeeded, pending, running, done, failed

    public var isSettled: Bool { self == .notNeeded || self == .done || self == .failed }
}

public enum ItemSource: String, Codable, Sendable {
    case recording, upload
}

/// One recording on its way to Hear Me Out. Persisted so work survives quitting or a crash.
///
/// Processing runs on independent tracks so the share link never waits for local AI work:
/// * upload   pending → ticketed → uploaded → ready (fast finalise, `transcribe:false`)
/// * transcript (local Whisper, or fetched after cloud transcription)
/// * cloud     finalise `transcribe:true` (cloud mode only)
/// * title     Apple Intelligence / OpenAI, once a transcript exists
/// * sync      a second finalise that attaches the local transcript and/or generated title
public struct QueueItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The account selected when recording began (or chosen explicitly on import). Never changes implicitly.
    public var accountId: String
    public var createdAt: Date
    public var recordedAt: Date
    public var recordedAtIsEstimated: Bool
    public var durationSeconds: Double
    public var sizeBytes: Int64
    public var fileExtension: String
    public var mimeType: String
    public var originalFilename: String?
    /// File name inside the app's audio folder.
    public var audioFileName: String
    public var source: ItemSource

    /// A title the user typed. Always wins over generated titles.
    public var userTitle: String?
    public var preferences: ProcessingPreferences

    public var recordingId: String?
    public var ticket: UploadTicket?
    public var upload: UploadStage
    public var share: ShareLinks?
    public var remoteTitle: String?
    public var remoteTitleIsAi: Bool?
    public var remoteTranscriptionStatus: String?

    public var transcript: String?
    public var transcriptStage: TrackStage
    public var cloudStage: TrackStage
    public var generatedTitle: String?
    public var titleStage: TrackStage
    public var syncStage: TrackStage

    public var attempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    /// Something needs the user (permanent failure or decision).
    public var needsAttention: Bool
    public var cancelled: Bool
    public var finishedAt: Date?
    /// The local audio may be removed (it is on the server and the user no longer needs a cached copy).
    public var audioRemoved: Bool

    public init(id: UUID = UUID(), accountId: String, createdAt: Date = Date(), recordedAt: Date, recordedAtIsEstimated: Bool = false,
                durationSeconds: Double, sizeBytes: Int64, fileExtension: String, mimeType: String? = nil,
                originalFilename: String?, audioFileName: String, source: ItemSource, userTitle: String?,
                preferences: ProcessingPreferences) {
        self.id = id
        self.accountId = accountId
        self.createdAt = createdAt
        self.recordedAt = recordedAt
        self.recordedAtIsEstimated = recordedAtIsEstimated
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.fileExtension = fileExtension.lowercased()
        self.mimeType = mimeType ?? AudioFormat.mimeType(forExtension: fileExtension)
        self.originalFilename = originalFilename
        self.audioFileName = audioFileName
        self.source = source
        let t = userTitle?.trimmed
        self.userTitle = (t?.isEmpty ?? true) || t == HMOLimits.serverDefaultTitle ? nil : String(t!.prefix(HMOLimits.maxTitleLength))
        self.preferences = preferences
        self.upload = .pending
        self.transcriptStage = .notNeeded
        self.cloudStage = .notNeeded
        self.titleStage = .notNeeded
        self.syncStage = .notNeeded
        self.attempts = 0
        self.needsAttention = false
        self.cancelled = false
        self.audioRemoved = false
        Pipeline.configureTracks(&self)
    }

    public var isFinished: Bool { finishedAt != nil }

    /// The best title to display right now.
    public var displayTitle: String {
        if let t = userTitle { return t }
        if let t = generatedTitle { return t }
        if let t = remoteTitle, t != HMOLimits.serverDefaultTitle, !ProvisionalTitle.isProvisional(t) { return t }
        if let n = originalFilename, source == .upload { return (n as NSString).deletingPathExtension }
        return ProvisionalTitle.make(for: recordedAt)
    }

    /// Short, friendly status for cards and the Activity view.
    public var statusLabel: String {
        if cancelled { return "Cancelled" }
        if needsAttention { return "Needs attention" }
        switch upload {
        case .pending: return nextAttemptAt != nil ? "Waiting to upload" : "Preparing"
        case .ticketed: return "Uploading"
        case .uploaded: return "Confirming"
        case .ready: break
        }
        if transcriptStage == .running { return "Transcribing on this Mac" }
        if cloudStage == .running || (cloudStage == .done && transcriptStage == .pending) { return "Transcribing in the cloud" }
        if titleStage == .running { return "Writing a title" }
        if syncStage == .running { return "Saving transcript" }
        if isFinished { return "Ready to share" }
        return "Ready to share · finishing"
    }
}
