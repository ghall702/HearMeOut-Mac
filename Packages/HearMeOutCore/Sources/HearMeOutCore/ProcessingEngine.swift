import Foundation
import Combine

/// Backoff for transient failures: 5 s, 15 s, 45 s, 2 min, 5 min, then 10 min, up to `maxAttempts`.
public struct RetryPolicy: Sendable {
    public var delays: [TimeInterval]
    public var maxAttempts: Int

    public init(delays: [TimeInterval] = [5, 15, 45, 120, 300, 600], maxAttempts: Int = 8) {
        self.delays = delays
        self.maxAttempts = maxAttempts
    }

    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard !delays.isEmpty else { return 0 }
        return delays[min(max(attempt - 1, 0), delays.count - 1)]
    }

    public static let immediate = RetryPolicy(delays: [0], maxAttempts: 3)
}

/// Failures from the direct PUT to the media server.
public enum UploadError: Error, Equatable, LocalizedError, Sendable {
    /// 401/403 from the media server: the signed token expired or was rejected.
    case tokenRejected
    /// 409: the recording was already finalised.
    case alreadyFinalised
    case tooLarge
    case server(Int)
    case network(String)
    case fileMissing

    public var errorDescription: String? {
        switch self {
        case .tokenRejected: return "The upload ticket expired."
        case .alreadyFinalised: return "The recording was already saved."
        case .tooLarge: return "The file is larger than Hear Me Out allows (500 MB)."
        case .server(let c): return "The storage server returned an error (\(c)). This will be retried."
        case .network: return "The upload was interrupted. It will resume when you're back online."
        case .fileMissing: return "The audio file is missing from this Mac."
        }
    }

    public var isTransient: Bool {
        switch self {
        case .network: return true
        case .server(let c): return c >= 500 || c == 408 || c == 429
        default: return false
        }
    }
}

/// Errors from title providers, classified for retry.
public struct TitleError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var isTransient: Bool
    public init(_ message: String, transient: Bool = false) {
        self.message = message
        self.isTransient = transient
    }
    public var errorDescription: String? { message }
}

/// Local transcription failure (unsupported format, missing model, …). Never retried automatically.
public struct TranscriptionError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What the engine needs from the app. Implemented by the app with URLSession, WhisperKit, etc.
@MainActor
public protocol PipelineServices: AnyObject {
    /// The API client for this account, or nil if the account is gone or needs reconnecting.
    func client(for accountId: String) -> HMOClient?
    func audioURL(for item: QueueItem) -> URL
    func uploadFile(_ url: URL, ticket: UploadTicket, itemId: UUID, progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ url: URL, itemId: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    func generateTitle(transcript: String, provider: TitleProvider, accountId: String) async throws -> String
}

/// Runs the pipeline for every queued recording: independent of any view, durable, retrying,
/// account-isolated (each item always uses the client of its own account).
@MainActor
public final class ProcessingEngine: ObservableObject {
    @Published public private(set) var items: [QueueItem]
    @Published public private(set) var uploadProgress: [UUID: Double] = [:]
    @Published public private(set) var transcriptionProgress: [UUID: Double] = [:]
    @Published public private(set) var pausedAccounts: Set<String> = []

    public var isOnline = true {
        didSet { if isOnline && !oldValue { wakeAllForConnectivity() } }
    }
    public var maxConcurrentTranscriptions = 1
    public var maxConcurrentTitles = 2
    public var maxConcurrentUploads = 2
    public var cloudPollInterval: TimeInterval = 15
    public var maxCloudPolls = 60
    public var retry: RetryPolicy

    public var onChange: (([QueueItem]) -> Void)?
    public var onAuthFailure: ((String) -> Void)?
    public var onBecameShareable: ((QueueItem) -> Void)?
    public var onFinished: ((QueueItem) -> Void)?

    public weak var services: PipelineServices?
    private var running: [UUID: Set<PipelineAction>] = [:]
    private var cloudPolls: [UUID: Int] = [:]
    private var wakeTask: Task<Void, Never>?
    private var tasks: [UUID: [Task<Void, Never>]] = [:]

    public init(items: [QueueItem] = [], retry: RetryPolicy = RetryPolicy()) {
        self.items = items
        self.retry = retry
        recoverAfterLaunch()
    }

    // MARK: Queries

    public func item(_ id: UUID) -> QueueItem? { items.first { $0.id == id } }
    public func isRunning(_ id: UUID, _ action: PipelineAction) -> Bool { running[id]?.contains(action) ?? false }
    public var activeItems: [QueueItem] { items.filter { !$0.isFinished && !$0.cancelled } }
    public func items(for accountId: String) -> [QueueItem] { items.filter { $0.accountId == accountId } }

    // MARK: Mutations

    public func add(_ item: QueueItem) {
        items.insert(item, at: 0)
        changed()
        pump()
    }

    public func update(_ id: UUID, _ mutate: (inout QueueItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[i])
        Pipeline.settle(&items[i])
        changed()
    }

    /// Manual retry: clears backoff and puts failed tracks back in the queue.
    public func retryNow(_ id: UUID) {
        update(id) { it in
            it.needsAttention = false
            it.attempts = 0
            it.nextAttemptAt = nil
            it.lastError = nil
            it.finishedAt = nil
            if it.preferences.transcription == .local && it.transcriptStage == .failed { it.transcriptStage = .pending }
            if it.preferences.transcription == .cloud && it.transcriptStage == .failed { it.transcriptStage = .pending; it.cloudStage = .pending }
            if it.titleStage == .failed && Pipeline.needsAppTitle(it) { it.titleStage = .pending }
            if it.syncStage == .failed { it.syncStage = .pending }
        }
        cloudPolls[id] = nil
        pump()
    }

    public func cancel(_ id: UUID) {
        tasks[id]?.forEach { $0.cancel() }
        update(id) { $0.cancelled = true; $0.nextAttemptAt = nil }
    }

    public func remove(_ id: UUID) {
        tasks[id]?.forEach { $0.cancel() }
        tasks[id] = nil
        running[id] = nil
        items.removeAll { $0.id == id }
        changed()
    }

    public func switchToCloudTranscription(_ id: UUID) {
        update(id) { Pipeline.switchToCloudTranscription(&$0) }
        pump()
    }

    public func retryTitle(_ id: UUID, provider: TitleProvider? = nil) {
        update(id) { Pipeline.retryTitle(&$0, provider: provider) }
        pump()
    }

    public func rename(_ id: UUID, to title: String) {
        update(id) { Pipeline.setUserTitle(&$0, title) }
        pump()
    }

    /// Moves a recording to another account. Only allowed before anything was created on the server,
    /// and only when the user explicitly asks.
    @discardableResult
    public func reassign(_ id: UUID, to accountId: String, preferences: ProcessingPreferences) -> Bool {
        guard let it = item(id), it.recordingId == nil, it.upload == .pending, !isRunning(id, .createUpload) else { return false }
        update(id) { x in
            x.accountId = accountId
            x.preferences = preferences
            let transcript = x.transcript
            let stage = x.transcriptStage
            Pipeline.configureTracks(&x)
            if preferences.transcription == .local && stage == .done { x.transcript = transcript; x.transcriptStage = .done }
        }
        pump()
        return true
    }

    public func resumeAccount(_ accountId: String) {
        pausedAccounts.remove(accountId)
        for it in items where it.accountId == accountId && it.lastError == HMOError.unauthorised.errorDescription {
            update(it.id) { $0.lastError = nil; $0.nextAttemptAt = nil }
        }
        pump()
    }

    public func pauseAccount(_ accountId: String) {
        pausedAccounts.insert(accountId)
    }

    /// Stages left "running" by a previous launch go back to pending (their tasks died with the process).
    public func recoverAfterLaunch() {
        for i in items.indices {
            if items[i].transcriptStage == .running { items[i].transcriptStage = .pending }
            if items[i].titleStage == .running { items[i].titleStage = .pending }
            if items[i].syncStage == .running { items[i].syncStage = .pending }
            if items[i].cloudStage == .running {
                // The request may have completed server-side: check the status rather than re-requesting.
                items[i].cloudStage = .done
            }
        }
    }

    // MARK: Scheduling

    /// Starts everything that can run now.
    public func pump() {
        guard let services else { return }
        let now = Date()
        for item in items {
            for action in Pipeline.nextActions(for: item) where canStart(action, item: item, now: now, services: services) {
                start(action, itemId: item.id)
            }
        }
        scheduleWake()
    }

    private func count(_ action: PipelineAction) -> Int { running.values.reduce(0) { $0 + ($1.contains(action) ? 1 : 0) } }

    private func canStart(_ action: PipelineAction, item: QueueItem, now: Date, services: PipelineServices) -> Bool {
        if isRunning(item.id, action) { return false }
        if action.needsNetwork {
            if !isOnline || pausedAccounts.contains(item.accountId) { return false }
            if let t = item.nextAttemptAt, t > now { return false }
            if services.client(for: item.accountId) == nil { return false }
            // One server conversation per item at a time keeps finalise calls ordered.
            let busy = running[item.id] ?? []
            if !busy.filter({ $0.needsNetwork }).isEmpty { return false }
        }
        switch action {
        case .transcribeLocally: return count(.transcribeLocally) < maxConcurrentTranscriptions
        case .generateTitle:
            if let t = item.nextAttemptAt, t > now { return false }
            return count(.generateTitle) < maxConcurrentTitles
        case .upload: return count(.upload) < maxConcurrentUploads
        default: return true
        }
    }

    private func start(_ action: PipelineAction, itemId: UUID) {
        running[itemId, default: []].insert(action)
        update(itemId) { it in
            switch action {
            case .transcribeLocally: it.transcriptStage = .running
            case .generateTitle: it.titleStage = .running
            case .requestCloudTranscription: it.cloudStage = .running
            case .sync: it.syncStage = .running
            default: break
            }
        }
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform(action, itemId: itemId)
            self.running[itemId]?.remove(action)
            if self.running[itemId]?.isEmpty == true { self.running[itemId] = nil }
            self.update(itemId) { _ in }
            if let it = self.item(itemId) {
                if it.isFinished { self.onFinished?(it) }
            }
            self.pump()
        }
        tasks[itemId, default: []].append(t)
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        let now = Date()
        let next = items.filter { !$0.cancelled && !$0.isFinished }.compactMap(\.nextAttemptAt).filter { $0 > now }.min()
        guard let next else { return }
        let delay = max(0.5, next.timeIntervalSince(now))
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func wakeAllForConnectivity() {
        // Coming back online: network failures shouldn't keep waiting out a long backoff.
        for it in items where it.nextAttemptAt != nil && !it.needsAttention {
            update(it.id) { $0.nextAttemptAt = nil }
        }
        pump()
    }

    private func changed() {
        onChange?(items)
    }

    // MARK: Actions

    private func perform(_ action: PipelineAction, itemId: UUID) async {
        guard let services, let item = item(itemId) else { return }
        do {
            switch action {
            case .createUpload: try await createUpload(item, services)
            case .upload: try await upload(item, services)
            case .fastFinalize: try await fastFinalize(item, services)
            case .transcribeLocally: try await transcribeLocally(item, services)
            case .requestCloudTranscription: try await requestCloud(item, services)
            case .fetchCloudTranscript: try await fetchCloudTranscript(item, services)
            case .generateTitle: try await generateTitle(item, services)
            case .sync: try await sync(item, services)
            }
            if action.needsNetwork { update(itemId) { $0.attempts = 0; $0.nextAttemptAt = nil } }
        } catch is CancellationError {
            revertRunning(action, itemId)
        } catch {
            handle(error, action: action, itemId: itemId)
        }
    }

    private func requireClient(_ item: QueueItem, _ services: PipelineServices) throws -> HMOClient {
        guard let c = services.client(for: item.accountId) else { throw HMOError.unauthorised }
        return c
    }

    private func createUpload(_ item: QueueItem, _ services: PipelineServices) async throws {
        guard HMOLimits.durationIsAcceptable(item.durationSeconds) else {
            throw PermanentFailure("This recording is longer than Hear Me Out's 15-minute limit.")
        }
        guard item.sizeBytes > 0, item.sizeBytes <= HMOLimits.maxUploadBytes else {
            throw PermanentFailure("This file is larger than Hear Me Out's 500 MB limit.")
        }
        guard FileManager.default.fileExists(atPath: services.audioURL(for: item).path) else { throw UploadError.fileMissing }
        let client = try requireClient(item, services)
        let ticket = try await client.createUpload(Pipeline.createUploadRequest(for: item))
        update(item.id) { $0.recordingId = ticket.recordingId; $0.ticket = ticket; $0.upload = .ticketed }
    }

    private func freshTicket(_ item: QueueItem, _ client: HMOClient) async throws -> UploadTicket? {
        guard let id = item.recordingId else { throw PermanentFailure("Missing recording id.") }
        do {
            let t = try await client.reissueUpload(recordingId: id)
            update(item.id) { $0.ticket = t }
            return t
        } catch HMOError.conflict {
            update(item.id) { $0.upload = .uploaded }   // already finalised server-side
            return nil
        }
    }

    private func upload(_ item: QueueItem, _ services: PipelineServices) async throws {
        let client = try requireClient(item, services)
        let url = services.audioURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { throw UploadError.fileMissing }
        var ticket = item.ticket
        if ticket == nil || ticket!.isExpiring() {
            guard let t = try await freshTicket(item, client) else { return }
            ticket = t
        }
        let id = item.id
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.uploadProgress[id] = p }
        }
        do {
            try await services.uploadFile(url, ticket: ticket!, itemId: id, progress: report)
        } catch UploadError.tokenRejected {
            guard let t = try await freshTicket(item, client) else { return }
            try await services.uploadFile(url, ticket: t, itemId: id, progress: report)
        } catch UploadError.alreadyFinalised {
            // fall through: treat as uploaded
        }
        uploadProgress[id] = nil
        update(id) { $0.upload = .uploaded }
    }

    private func fastFinalize(_ item: QueueItem, _ services: PipelineServices) async throws {
        let client = try requireClient(item, services)
        guard let rid = item.recordingId else { throw PermanentFailure("Missing recording id.") }
        do {
            let r = try await client.finalize(recordingId: rid, Pipeline.fastFinalizeRequest(for: item), timeout: 60)
            update(item.id) { it in
                it.upload = .ready
                it.share = ShareLinks(shareUrl: r.shareUrl, embedUrl: r.embedUrl, embedCode: r.embedCode)
                it.remoteTitle = r.title
                it.remoteTitleIsAi = r.title_is_ai
                it.remoteTranscriptionStatus = r.transcription_status
            }
            if let it = self.item(item.id) { onBecameShareable?(it) }
        } catch HMOError.http(400, let code) {
            // The server couldn't find the file: upload it again with a fresh ticket.
            update(item.id) { it in
                it.upload = .ticketed
                it.ticket?.exp = 0
                it.attempts += 1
                if it.attempts > 3 { it.needsAttention = true; it.lastError = "The storage server didn't confirm the upload (\(code))." }
            }
        }
    }

    private func transcribeLocally(_ item: QueueItem, _ services: PipelineServices) async throws {
        let id = item.id
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.transcriptionProgress[id] = p }
        }
        let text = try await services.transcribe(services.audioURL(for: item), itemId: id, progress: report)
        transcriptionProgress[id] = nil
        let clean = text.trimmed
        update(id) { it in
            it.transcript = clean.isEmpty ? HMOLimits.noSpeechTranscript : clean
            it.transcriptStage = .done
        }
    }

    private func requestCloud(_ item: QueueItem, _ services: PipelineServices) async throws {
        let client = try requireClient(item, services)
        guard let rid = item.recordingId else { throw PermanentFailure("Missing recording id.") }
        do {
            let r = try await client.finalize(recordingId: rid, FinalizeRequest(transcribe: true), timeout: 240)
            update(item.id) { it in
                it.cloudStage = .done
                it.remoteTranscriptionStatus = r.transcription_status
                if let t = r.title { it.remoteTitle = t }
                it.remoteTitleIsAi = r.title_is_ai
            }
        } catch HMOError.network {
            // A long request may have been cut off while the server keeps working: poll instead of re-requesting.
            update(item.id) { $0.cloudStage = .done }
        }
    }

    private func fetchCloudTranscript(_ item: QueueItem, _ services: PipelineServices) async throws {
        let client = try requireClient(item, services)
        guard let rid = item.recordingId else { throw PermanentFailure("Missing recording id.") }
        let r = try await client.recording(id: rid)
        update(item.id) { it in
            it.remoteTranscriptionStatus = r.transcription_status
            it.remoteTitle = r.title
            it.remoteTitleIsAi = r.title_is_ai
        }
        switch r.transcription_status {
        case "done":
            cloudPolls[item.id] = nil
            update(item.id) { $0.transcript = r.transcript ?? HMOLimits.noSpeechTranscript; $0.transcriptStage = .done }
        case "failed":
            cloudPolls[item.id] = nil
            update(item.id) { it in
                it.transcriptStage = .failed
                it.lastError = "Cloud transcription failed" + (r.transcription_error.map { ": \($0)" } ?? ".")
            }
        case "none", nil:
            // Transcription never started (e.g. the request was cut off before it began): ask once more.
            let polls = (cloudPolls[item.id] ?? 0) + 1
            cloudPolls[item.id] = polls
            if polls > 2 {
                update(item.id) { $0.transcriptStage = .failed; $0.lastError = "Hear Me Out didn't start transcribing this recording." }
            } else {
                update(item.id) { $0.cloudStage = .pending }
            }
        default:
            let polls = (cloudPolls[item.id] ?? 0) + 1
            cloudPolls[item.id] = polls
            if polls > maxCloudPolls {
                update(item.id) { $0.transcriptStage = .failed; $0.lastError = "Cloud transcription is taking longer than expected. Refresh later." }
            } else {
                let wait = cloudPollInterval
                update(item.id) { $0.nextAttemptAt = Date().addingTimeInterval(wait) }
                throw PollAgain()
            }
        }
    }

    private func generateTitle(_ item: QueueItem, _ services: PipelineServices) async throws {
        guard let transcript = item.transcript else { return }
        let raw = try await services.generateTitle(transcript: transcript, provider: item.preferences.titleProvider, accountId: item.accountId)
        guard let title = TitleSanitiser.clean(raw) else { throw TitleError("The title provider returned an unusable title.") }
        update(item.id) { it in
            if it.userTitle == nil { it.generatedTitle = title; it.titleStage = .done } else { it.titleStage = .notNeeded }
        }
    }

    private func sync(_ item: QueueItem, _ services: PipelineServices) async throws {
        guard let req = Pipeline.syncRequest(for: item) else {
            update(item.id) { $0.syncStage = .notNeeded }
            return
        }
        let client = try requireClient(item, services)
        guard let rid = item.recordingId else { throw PermanentFailure("Missing recording id.") }
        do {
            let r = try await client.finalize(recordingId: rid, req, timeout: 90)
            update(item.id) { it in
                it.syncStage = .done
                if let t = r.title { it.remoteTitle = t }
                it.remoteTitleIsAi = r.title_is_ai
                it.remoteTranscriptionStatus = r.transcription_status
            }
        } catch let e as HMOError where !e.isTransient && e != .unauthorised {
            update(item.id) { it in
                it.syncStage = .failed
                it.lastError = "Hear Me Out didn't accept the transcript or title (\(e.localizedDescription)). It's kept on this Mac."
            }
        }
    }

    // MARK: Failure handling

    private func revertRunning(_ action: PipelineAction, _ id: UUID) {
        update(id) { it in
            switch action {
            case .transcribeLocally: if it.transcriptStage == .running { it.transcriptStage = .pending }
            case .generateTitle: if it.titleStage == .running { it.titleStage = .pending }
            case .requestCloudTranscription: if it.cloudStage == .running { it.cloudStage = .pending }
            case .sync: if it.syncStage == .running { it.syncStage = .pending }
            default: break
            }
        }
    }

    private func handle(_ error: Error, action: PipelineAction, itemId: UUID) {
        if error is PollAgain { return }
        revertRunning(action, itemId)
        guard let item = item(itemId) else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        if case HMOError.unauthorised = error {
            pausedAccounts.insert(item.accountId)
            update(itemId) { $0.lastError = message }
            onAuthFailure?(item.accountId)
            return
        }

        let transient: Bool
        switch error {
        case let e as HMOError: transient = e.isTransient
        case let e as UploadError: transient = e.isTransient
        case let e as TitleError: transient = e.isTransient
        case is URLError: transient = true
        default: transient = false
        }

        if transient {
            update(itemId) { it in
                it.attempts += 1
                it.lastError = message
                let limit = action == .generateTitle ? 4 : retry.maxAttempts
                if it.attempts >= limit {
                    switch action {
                    case .generateTitle: it.titleStage = .failed
                    case .sync: it.syncStage = .failed
                    default: it.needsAttention = true
                    }
                    it.nextAttemptAt = nil
                } else {
                    it.nextAttemptAt = Date().addingTimeInterval(retry.delay(afterAttempt: it.attempts))
                }
            }
            return
        }

        // Permanent failures: keep the audio and anything already made, and explain.
        update(itemId) { it in
            switch action {
            case .transcribeLocally:
                it.transcriptStage = .failed
                it.lastError = "Local transcription failed: \(message)"
            case .generateTitle:
                it.titleStage = .failed
                it.lastError = "Title not generated: \(message)"
            case .fetchCloudTranscript:
                it.transcriptStage = .failed
                it.lastError = message
            case .requestCloudTranscription:
                it.cloudStage = .failed
                it.transcriptStage = .failed
                it.lastError = "Cloud transcription couldn't start: \(message)"
            case .sync:
                it.syncStage = .failed
                it.lastError = message
            case .createUpload, .upload, .fastFinalize:
                it.needsAttention = true
                it.lastError = message
            }
        }
    }
}

/// A failure that retrying won't fix (too long, too large, missing data).
public struct PermanentFailure: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

struct PollAgain: Error {}
