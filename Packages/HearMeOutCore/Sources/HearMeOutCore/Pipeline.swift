import Foundation

/// Work the engine can start for an item right now.
public enum PipelineAction: String, Equatable, Hashable, Sendable, CaseIterable {
    case createUpload
    case upload
    case fastFinalize
    case transcribeLocally
    case requestCloudTranscription
    case fetchCloudTranscript
    case generateTitle
    case sync

    /// Actions that need the network (paused while offline).
    public var needsNetwork: Bool { self != .transcribeLocally && self != .generateTitle }
}

/// Pure decision logic for the processing pipeline. No I/O, fully unit tested.
public enum Pipeline {

    /// Sets the initial track stages from the item's preferences.
    public static func configureTracks(_ item: inout QueueItem) {
        let p = item.preferences
        switch p.transcription {
        case .local:
            item.transcriptStage = .pending
            item.cloudStage = .notNeeded
        case .cloud:
            item.transcriptStage = .pending   // filled by fetching after cloud transcription
            item.cloudStage = .pending
        case .none:
            item.transcriptStage = .notNeeded
            item.cloudStage = .notNeeded
        }
        item.titleStage = needsAppTitle(item) ? .pending : .notNeeded
        switch p.transcription {
        case .local: item.syncStage = .pending
        case .cloud: item.syncStage = item.titleStage == .pending ? .pending : .notNeeded
        case .none: item.syncStage = .notNeeded
        }
    }

    /// Whether this app must produce the title (Apple Intelligence or OpenAI, no typed title, a transcript will exist).
    public static func needsAppTitle(_ item: QueueItem) -> Bool {
        item.userTitle == nil && item.preferences.titleProvider.isGeneratedByApp && item.preferences.transcription != .none
    }

    /// The title sent with the first (fast) finalise.
    ///
    /// * A typed title always goes first.
    /// * With Hear Me Out titling and a transcript coming, the title is omitted so the server's
    ///   auto-title runs (it only titles recordings still called "Untitled recording").
    /// * Otherwise a date-based provisional title is sent so the server never titles the recording
    ///   with a provider the user didn't choose. An app-generated title replaces it later.
    public static func fastFinalizeTitle(for item: QueueItem) -> String? {
        if let t = item.userTitle { return t }
        if item.preferences.titleProvider == .hearMeOut && item.preferences.transcription != .none { return nil }
        return ProvisionalTitle.make(for: item.recordedAt)
    }

    public static func fastFinalizeRequest(for item: QueueItem) -> FinalizeRequest {
        let title = fastFinalizeTitle(for: item)
        return FinalizeRequest(title: title, titleIsAi: title == nil ? nil : false, transcript: nil, transcribe: false,
                               recordedAt: RecordedAt.string(from: item.recordedAt))
    }

    public static func createUploadRequest(for item: QueueItem) -> CreateUploadRequest {
        CreateUploadRequest(ext: item.fileExtension, size: item.sizeBytes,
                            durationSeconds: (item.durationSeconds * 10).rounded() / 10,
                            filename: item.originalFilename ?? "voice-note.\(item.fileExtension)",
                            mime: item.mimeType, title: item.userTitle,
                            recordedAt: RecordedAt.string(from: item.recordedAt))
    }

    /// Whether a transcript can be used to make a title.
    public static func isUsableTranscript(_ t: String?) -> Bool {
        guard let t = t?.trimmed, !t.isEmpty else { return false }
        return t != HMOLimits.noSpeechTranscript
    }

    /// The second finalise that attaches local results. Nil when it would carry nothing.
    public static func syncRequest(for item: QueueItem) -> FinalizeRequest? {
        var r = FinalizeRequest(transcribe: false)
        if item.preferences.transcription == .local, item.transcriptStage == .done, let t = item.transcript?.trimmed, !t.isEmpty {
            r.transcript = String(t.prefix(HMOLimits.maxTranscriptLength))
        }
        if let u = item.userTitle {
            if r.transcript != nil || item.remoteTitle != u { r.title = u; r.titleIsAi = false }
        } else if item.titleStage == .done, let g = item.generatedTitle {
            r.title = g
            r.titleIsAi = true
        }
        if r.transcript == nil && r.title == nil { return nil }
        return r
    }

    /// Everything that may start now, in priority order. The engine filters out actions that are
    /// already running, waiting on backoff, or blocked by concurrency limits / connectivity.
    public static func nextActions(for item: QueueItem) -> [PipelineAction] {
        guard !item.cancelled, !item.isFinished else { return [] }
        var out: [PipelineAction] = []
        if !item.needsAttention {
            switch item.upload {
            case .pending: out.append(.createUpload)
            case .ticketed: out.append(.upload)
            case .uploaded: out.append(.fastFinalize)
            case .ready: break
            }
        }
        // Local transcription runs alongside the upload: it doesn't wait for the share link.
        if item.preferences.transcription == .local && item.transcriptStage == .pending && !item.audioRemoved {
            out.append(.transcribeLocally)
        }
        if item.upload == .ready && !item.needsAttention {
            if item.cloudStage == .pending { out.append(.requestCloudTranscription) }
            if item.preferences.transcription == .cloud && item.cloudStage == .done && item.transcriptStage == .pending {
                out.append(.fetchCloudTranscript)
            }
        }
        if item.titleStage == .pending && item.transcriptStage == .done && isUsableTranscript(item.transcript) {
            out.append(.generateTitle)
        }
        if item.upload == .ready && item.syncStage == .pending && !item.needsAttention && syncPrerequisitesMet(item) {
            out.append(.sync)
        }
        return out
    }

    static func syncPrerequisitesMet(_ item: QueueItem) -> Bool {
        let titleSettled = item.titleStage.isSettled
        switch item.preferences.transcription {
        case .local: return item.transcriptStage.isSettled && titleSettled
        case .cloud: return item.transcriptStage.isSettled && titleSettled
        case .none: return true
        }
    }

    /// Applies "nothing more can happen" transitions: a title can't be made from a failed or empty
    /// transcript, and the item finishes once every track has settled.
    public static func settle(_ item: inout QueueItem, now: Date = Date()) {
        if item.titleStage == .pending && item.transcriptStage.isSettled
            && !(item.transcriptStage == .done && isUsableTranscript(item.transcript)) {
            item.titleStage = .notNeeded
        }
        if item.syncStage == .pending && item.upload == .ready && syncPrerequisitesMet(item) && syncRequest(for: item) == nil {
            item.syncStage = .notNeeded
        }
        let settled = item.upload == .ready && item.transcriptStage.isSettled && item.cloudStage.isSettled
            && item.titleStage.isSettled && item.syncStage.isSettled
        if settled && item.finishedAt == nil && !item.cancelled {
            item.finishedAt = now
            item.nextAttemptAt = nil
            if !item.transcriptFailedOnly { item.lastError = nil }
        }
    }

    /// Switches a recording to cloud transcription after local transcription failed (explicit user action).
    public static func switchToCloudTranscription(_ item: inout QueueItem) {
        item.preferences.transcription = .cloud
        item.transcript = nil
        item.transcriptStage = .pending
        item.cloudStage = .pending
        item.titleStage = needsAppTitle(item) ? .pending : .notNeeded
        item.syncStage = item.titleStage == .pending ? .pending : .notNeeded
        item.finishedAt = nil
        item.needsAttention = false
        item.lastError = nil
        item.attempts = 0
        item.nextAttemptAt = nil
    }

    /// Asks for a new generated title (e.g. after an OpenAI quota error was fixed).
    public static func retryTitle(_ item: inout QueueItem, provider: TitleProvider? = nil) {
        if let provider { item.preferences.titleProvider = provider }
        guard needsAppTitle(item) else { return }
        item.generatedTitle = nil
        item.titleStage = .pending
        item.syncStage = .pending
        item.finishedAt = nil
        item.needsAttention = false
        item.lastError = nil
    }

    /// The user typed a title after saving. It is sent with the next sync (or a title-only sync).
    public static func setUserTitle(_ item: inout QueueItem, _ title: String) {
        let t = title.trimmed
        guard !t.isEmpty else { return }
        item.userTitle = String(t.prefix(HMOLimits.maxTitleLength))
        if item.titleStage == .pending || item.titleStage == .running { item.titleStage = .notNeeded }
        if item.upload == .ready {
            item.syncStage = .pending
            item.finishedAt = nil
        }
    }
}

extension QueueItem {
    /// Finished, but the transcript failed: keep the explanation visible.
    var transcriptFailedOnly: Bool { transcriptStage == .failed || titleStage == .failed || syncStage == .failed }
}

extension Pipeline {
    /// Title-only update when the user renames a finished recording.
    public static func titleOnlyRequest(for item: QueueItem) -> FinalizeRequest? {
        guard let u = item.userTitle else { return nil }
        return FinalizeRequest(title: u, titleIsAi: false, transcribe: false)
    }
}
