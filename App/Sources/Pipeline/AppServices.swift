import Foundation
import HearMeOutCore

/// Connects the core pipeline to the app's real services. Each recording uses the client of the
/// account it belongs to — never the account currently on screen.
@MainActor
final class AppServices: PipelineServices {
    weak var model: AppModel?
    let whisper: WhisperEngine

    init(whisper: WhisperEngine) {
        self.whisper = whisper
    }

    func client(for accountId: String) -> HMOClient? {
        guard let model, let account = model.accounts.first(where: { $0.id == accountId }), !account.needsReconnect else { return nil }
        if model.isDemo { return nil }
        guard let key = model.apiKey(for: accountId) else { return nil }
        return HMOClient(apiKey: key)
    }

    func audioURL(for item: QueueItem) -> URL {
        AppPaths.audio.appendingPathComponent(item.audioFileName)
    }

    func uploadFile(_ url: URL, ticket: UploadTicket, itemId: UUID, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await UploadManager.shared.upload(file: url, ticket: ticket, itemId: itemId, onProgress: progress)
    }

    func transcribe(_ url: URL, itemId: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await whisper.transcribe(url, progress: progress)
    }

    func generateTitle(transcript: String, provider: TitleProvider, accountId: String) async throws -> String {
        switch provider {
        case .appleIntelligence:
            return try await AppleTitleGenerator.title(for: transcript)
        case .openAI:
            let model = model?.settings.openAIModel ?? OpenAITitleGenerator.preferred[0]
            return try await OpenAITitleGenerator.title(for: transcript, model: model)
        case .hearMeOut, .manual:
            throw TitleError("This provider doesn't generate titles in the app.")
        }
    }
}
