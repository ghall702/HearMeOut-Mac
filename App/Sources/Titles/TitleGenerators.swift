import Foundation
import HearMeOutCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device Foundation Models (Apple Intelligence). Nothing leaves the Mac.
enum AppleTitleGenerator {
    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This Mac doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri.")
                case .modelNotReady: return .unavailable("Apple Intelligence is still downloading its model. Try again shortly.")
                @unknown default: return .unavailable("Apple Intelligence isn't available right now.")
                }
            }
        }
        return .unavailable("Apple Intelligence titles need macOS 26 or later.")
        #else
        return .unavailable("This build of Hear Me Out was made without Apple Intelligence support.")
        #endif
    }

    static func title(for transcript: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = availability else {
                if case .unavailable(let why) = availability { throw TitleError(why) }
                throw TitleError("Apple Intelligence isn't available.")
            }
            let session = LanguageModelSession(instructions: TitleSanitiser.instructions)
            let prompt = "Write a title for this voice note transcript:\n\n\(TitleSanitiser.excerpt(transcript, limit: 4000))"
            do {
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 40))
                return response.content
            } catch {
                throw TitleError("Apple Intelligence couldn't write a title (\(error.localizedDescription)).")
            }
        }
        #endif
        throw TitleError("Apple Intelligence titles need macOS 26 or later.")
    }
}

/// OpenAI title generation with the user's own key (Keychain). Sends only a transcript excerpt.
enum OpenAITitleGenerator {
    static let base = URL(string: "https://api.openai.com/v1")!
    /// Preferred small, inexpensive models, in order. The actual list comes from GET /v1/models.
    static let preferred = ["gpt-5-nano", "gpt-5-mini", "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4o-mini"]

    static var apiKey: String? { Keychain.get(Keychain.openAIAccount) }

    static func isReasoningModel(_ m: String) -> Bool {
        m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    /// Lists text models the key can use, newest-preferred first.
    static func availableModels(key: String) async throws -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else { throw error(from: data, status: resp.statusCode) }
        let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let usable = ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o")) && !["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "dall", "whisper", "moderation", "codex"].contains { id.contains($0) }
        }
        return usable.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? Int.max, ib = preferred.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
    }

    static func defaultModel(from models: [String]) -> String? {
        preferred.first { models.contains($0) } ?? models.first
    }

    static func title(for transcript: String, model: String) async throws -> String {
        guard let key = apiKey, !key.isEmpty else { throw TitleError("Add your OpenAI API key in Settings → AI Titles.") }
        var body: [String: Any] = [
            "model": model,
            "instructions": TitleSanitiser.instructions,
            "input": "Write a title for this voice note transcript:\n\n\(TitleSanitiser.excerpt(transcript))",
            "store": false,
        ]
        if isReasoningModel(model) {
            body["reasoning"] = ["effort": "minimal"]
            body["max_output_tokens"] = 400
        } else {
            body["max_output_tokens"] = 40
            body["temperature"] = 0.3
        }
        var req = URLRequest(url: base.appendingPathComponent("responses"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 45
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var (data, resp) = try await send(req)
        if resp.statusCode == 400, body["reasoning"] != nil, String(data: data, encoding: .utf8)?.contains("reasoning") == true {
            body["reasoning"] = nil
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            (data, resp) = try await send(req)
        }
        guard resp.statusCode == 200 else { throw error(from: data, status: resp.statusCode) }
        guard let text = outputText(data), !text.isEmpty else { throw TitleError("OpenAI returned no title.") }
        return text
    }

    /// Extracts text from a Responses API result.
    static func outputText(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let t = obj["output_text"] as? String { return t }
        let outputs = obj["output"] as? [[String: Any]] ?? []
        let texts = outputs.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { c -> String? in
            (c["type"] as? String) == "output_text" ? c["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// A one-line test used by "Test connection".
    static func test(key: String) async throws -> [String] {
        let models = try await availableModels(key: key)
        if models.isEmpty { throw TitleError("This key works but has no usable text models.") }
        return models
    }

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            guard let h = r as? HTTPURLResponse else { throw TitleError("No response from OpenAI.", transient: true) }
            return (d, h)
        } catch let e as TitleError {
            throw e
        } catch {
            throw TitleError("Couldn't reach OpenAI. It will be retried.", transient: true)
        }
    }

    static func error(from data: Data, status: Int) -> TitleError {
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let code = obj?["code"] as? String ?? ""
        let message = obj?["message"] as? String ?? ""
        switch status {
        case 401: return TitleError("OpenAI rejected the API key. Check it in Settings → AI Titles.")
        case 429:
            if code == "insufficient_quota" { return TitleError("Your OpenAI account has run out of credit. Top up, then choose Retry title.") }
            return TitleError("OpenAI is rate-limiting requests. It will be retried.", transient: true)
        case 404: return TitleError("That OpenAI model isn't available to your key. Choose another in Settings → AI Titles.")
        case 500...: return TitleError("OpenAI had a problem (\(status)). It will be retried.", transient: true)
        default: return TitleError(message.isEmpty ? "OpenAI returned an error (\(status))." : "OpenAI: \(message)")
        }
    }
}
