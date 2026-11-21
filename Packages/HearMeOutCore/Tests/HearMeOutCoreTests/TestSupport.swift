import Foundation
import XCTest
@testable import HearMeOutCore

/// Records every request and answers from a scripted handler.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Call { var method: String; var path: String; var body: [String: Any]; var auth: String? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var handler: (URLRequest, [String: Any]) throws -> (Int, Any)

    init(handler: @escaping (URLRequest, [String: Any]) throws -> (Int, Any)) { self.handler = handler }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let path = request.url!.path.replacingOccurrences(of: "/api/public/v1", with: "")
        lock.lock(); _calls.append(Call(method: request.httpMethod ?? "GET", path: path, body: body, auth: request.value(forHTTPHeaderField: "Authorization"))); lock.unlock()
        let (status, json) = try handler(request, body)
        let data = try JSONSerialization.data(withJSONObject: json)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func finalizeBodies() -> [[String: Any]] { calls.filter { $0.path.hasSuffix("/finalize") }.map(\.body) }
}

/// A fake Hear Me Out server with just enough state for the pipeline.
final class FakeServer: @unchecked Sendable {
    var title = "Untitled recording"
    var transcriptionStatus = "none"
    var transcript: String?
    var autoTitle = true
    var failNextFinalizeWith: Int?
    var reissueCount = 0
    let recordingId: String

    init(recordingId: String = "rec-1") { self.recordingId = recordingId }

    func handle(_ req: URLRequest, _ body: [String: Any]) throws -> (Int, Any) {
        let path = req.url!.path.replacingOccurrences(of: "/api/public/v1", with: "")
        switch (req.httpMethod ?? "GET", path) {
        case ("POST", "/uploads"):
            return (201, ["recordingId": recordingId, "key": "users/u/x.m4a", "url": "https://media.example/hmo/upload?key=x",
                          "token": "tok", "exp": Date().timeIntervalSince1970 + 3600, "method": "PUT", "headers": ["Authorization": "Bearer tok"]])
        case ("POST", "/recordings/\(recordingId)/upload-url"):
            reissueCount += 1
            return (200, ["recordingId": recordingId, "key": "users/u/x.m4a", "uploadUrl": "https://media.example/hmo/upload?key=x",
                          "method": "PUT", "headers": ["Authorization": "Bearer tok2"], "exp": Date().timeIntervalSince1970 + 3600])
        case ("POST", "/recordings/\(recordingId)/finalize"):
            if let s = failNextFinalizeWith { failNextFinalizeWith = nil; return (s, ["error": "boom"]) }
            if let t = body["title"] as? String { title = t }
            if let t = body["transcript"] as? String {
                transcript = t
                transcriptionStatus = "done"
                if body["title"] == nil && autoTitle && title == "Untitled recording" && t != "[No speech detected]" { title = "Cloud title" }
            }
            if body["transcribe"] as? Bool == true && transcript == nil {
                transcript = "cloud transcript text"
                transcriptionStatus = "done"
                if autoTitle && title == "Untitled recording" { title = "Cloud title" }
            }
            return (200, ["id": recordingId, "title": title, "title_is_ai": false, "transcription_status": transcriptionStatus,
                          "shareUrl": "https://hearmeout.george-hall.uk/s/abcdefghijklmnopqrstuvwxyz123456",
                          "embedUrl": "https://hearmeout.george-hall.uk/embed/abcdefghijklmnopqrstuvwxyz123456",
                          "embedCode": "<iframe></iframe>"])
        case ("GET", "/recordings/\(recordingId)"):
            var r: [String: Any] = ["id": recordingId, "title": title, "transcription_status": transcriptionStatus, "status": "ready"]
            if let transcript { r["transcript"] = transcript }
            return (200, r)
        default:
            return (404, ["error": "not_found"])
        }
    }
}

@MainActor
final class MockServices: PipelineServices {
    var clients: [String: HMOClient] = [:]
    var uploads: [(UUID, UploadTicket)] = []
    var uploadErrors: [Error] = []
    var transcriptResult: Result<String, Error> = .success("Hello Sam, great work on your essay.")
    var titleResult: Result<String, Error> = .success("\"Feedback on Sam's essay.\"")
    var titleCalls: [(String, TitleProvider)] = []
    var transcribeCalls = 0
    let dir: URL

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hmo-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func client(for accountId: String) -> HMOClient? { clients[accountId] }
    func audioURL(for item: QueueItem) -> URL { dir.appendingPathComponent(item.audioFileName) }
    func uploadFile(_ url: URL, ticket: UploadTicket, itemId: UUID, progress: @escaping @Sendable (Double) -> Void) async throws {
        if !uploadErrors.isEmpty { throw uploadErrors.removeFirst() }
        progress(1)
        uploads.append((itemId, ticket))
    }
    func transcribe(_ url: URL, itemId: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        transcribeCalls += 1
        return try transcriptResult.get()
    }
    func generateTitle(transcript: String, provider: TitleProvider, accountId: String) async throws -> String {
        titleCalls.append((transcript, provider))
        return try titleResult.get()
    }

    func makeItem(account: String = "acc-a", prefs: ProcessingPreferences, userTitle: String? = nil, duration: Double = 73.4) -> QueueItem {
        let name = "\(UUID().uuidString).m4a"
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(repeating: 1, count: 1000))
        return QueueItem(accountId: account, recordedAt: Date(timeIntervalSince1970: 1_763_631_000), durationSeconds: duration, sizeBytes: 1000,
                         fileExtension: "m4a", originalFilename: "memo.m4a", audioFileName: name, source: .recording,
                         userTitle: userTitle, preferences: prefs)
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
