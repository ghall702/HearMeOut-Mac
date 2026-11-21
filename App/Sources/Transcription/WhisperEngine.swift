import Foundation
import WhisperKit
import HearMeOutCore

/// Runs WhisperKit locally. The model loads lazily on the first job (never at launch), is reused
/// for following jobs, and is unloaded after a few idle minutes to give memory back. The engine
/// runs one transcription at a time so two large models never compete for memory.
actor WhisperEngine {
    private var pipe: WhisperKit?
    private var loadedFolder: String?
    private var idleTask: Task<Void, Never>?
    private var busy = false
    private let resolve: @Sendable () async -> (name: String, folder: URL, tokenizerBase: URL)?
    private let idleUnloadSeconds: UInt64

    init(idleUnloadSeconds: UInt64 = 180, resolve: @escaping @Sendable () async -> (name: String, folder: URL, tokenizerBase: URL)?) {
        self.resolve = resolve
        self.idleUnloadSeconds = idleUnloadSeconds
    }

    var isLoaded: Bool { pipe != nil }

    func unload() async {
        idleTask?.cancel()
        if let p = pipe { await p.unloadModels() }
        pipe = nil
        loadedFolder = nil
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let secs = idleUnloadSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard !busy else { return }
        await unload()
    }

    private func load(folder: URL, tokenizerBase: URL) async throws -> WhisperKit {
        if let p = pipe, loadedFolder == folder.path { return p }
        if let p = pipe { await p.unloadModels() }
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizerBase, verbose: false, logLevel: .none,
                                      prewarm: false, load: true, download: false)
        let p = try await WhisperKit(config)
        pipe = p
        loadedFolder = folder.path
        return p
    }

    /// Transcribes in English (Whisper has no separate British English model; spelling follows the speech).
    func transcribe(_ url: URL, language: String = "en", progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let model = await resolve() else {
            throw TranscriptionError("No Whisper model is set up. Choose one in Settings → Transcription, or switch this recording to cloud transcription.")
        }
        guard FileManager.default.fileExists(atPath: model.folder.path) else {
            throw TranscriptionError("The Whisper model folder is no longer available (it may have been removed from Let's Meet). Choose another model in Settings → Transcription.")
        }
        if !AudioFormat.isLocallyDecodable(url.pathExtension) {
            throw TranscriptionError("macOS can't decode .\(url.pathExtension) audio for local transcription. Use cloud transcription for this file.")
        }
        while busy { try await Task.sleep(nanoseconds: 200_000_000) }
        busy = true
        idleTask?.cancel()
        defer {
            busy = false
            scheduleIdleUnload()
        }
        let pipe: WhisperKit
        do {
            pipe = try await load(folder: model.folder, tokenizerBase: model.tokenizerBase)
        } catch {
            throw TranscriptionError("The Whisper model couldn't be loaded (\(error.localizedDescription)). If it's shared from Let's Meet, re-select its folder in Settings → Transcription.")
        }
        let options = DecodingOptions(verbose: false, task: .transcribe, language: language, temperature: 0,
                                      usePrefillPrompt: true, detectLanguage: false,
                                      skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: false,
                                      concurrentWorkerCount: 4, chunkingStrategy: .vad)
        let cancelled = CancelFlag()
        let progressObject = pipe.progress
        let poller = Task {
            while !Task.isCancelled {
                progress(min(0.99, progressObject.fractionCompleted))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }
        let results: [TranscriptionResult] = try await withTaskCancellationHandler {
            try await pipe.transcribe(audioPath: url.path, decodeOptions: options) { _ in cancelled.isSet ? false : nil }
        } onCancel: {
            cancelled.set()
        }
        try Task.checkCancellation()
        progress(1)
        let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }
        let text = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return Self.tidy(text)
    }

    /// Removes Whisper's bracketed non-speech markers and stray spacing.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|NOISE|SILENCE)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
