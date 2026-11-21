import XCTest
@testable import HearMeOutCore

@MainActor
final class PipelineTests: XCTestCase {

    func run(_ prefs: ProcessingPreferences, userTitle: String? = nil, configure: ((MockServices, FakeServer) -> Void)? = nil)
        async -> (QueueItem, MockTransport, FakeServer, MockServices) {
        let services = MockServices()
        let server = FakeServer()
        let transport = MockTransport(handler: server.handle)
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: transport)
        configure?(services, server)
        let engine = ProcessingEngine(retry: .immediate)
        engine.cloudPollInterval = 0.01
        engine.services = services
        let item = services.makeItem(prefs: prefs, userTitle: userTitle)
        engine.add(item)
        await waitUntil { engine.item(item.id)?.isFinished == true || engine.item(item.id)?.needsAttention == true }
        return (engine.item(item.id)!, transport, server, services)
    }

    // Local Whisper + Apple Intelligence: transcript, title, titleIsAi:true, transcribe:false.
    func testLocalTranscriptWithAppleTitle() async {
        let (item, transport, server, services) = await run(.init(transcription: .local, titleProvider: .appleIntelligence))
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(item.share?.shareUrl.contains("/s/"), true)
        let bodies = transport.finalizeBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["transcribe"] as? Bool, false, "first finalise must be fast")
        XCTAssertNil(bodies[0]["transcript"])
        XCTAssertTrue((bodies[0]["title"] as? String)?.hasPrefix("Voice note · ") == true, "provisional title blocks unrequested cloud titling")
        XCTAssertEqual(bodies[0]["recordedAt"] as? String, "2025-11-20T09:30:00Z")
        XCTAssertEqual(bodies[1]["transcript"] as? String, "Hello Sam, great work on your essay.")
        XCTAssertEqual(bodies[1]["title"] as? String, "Feedback on Sam's essay")
        XCTAssertEqual(bodies[1]["titleIsAi"] as? Bool, true)
        XCTAssertEqual(bodies[1]["transcribe"] as? Bool, false)
        XCTAssertEqual(server.title, "Feedback on Sam's essay")
        XCTAssertEqual(services.titleCalls.first?.1, .appleIntelligence)
    }

    func testLocalTranscriptWithOpenAITitle() async {
        let (item, transport, _, services) = await run(.init(transcription: .local, titleProvider: .openAI))
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(services.titleCalls.first?.1, .openAI)
        XCTAssertEqual(transport.finalizeBodies().last?["titleIsAi"] as? Bool, true)
    }

    // Local Whisper + Hear Me Out title: transcript without a title so the backend auto-titles.
    func testLocalTranscriptWithCloudTitle() async {
        let (item, transport, server, services) = await run(.init(transcription: .local, titleProvider: .hearMeOut))
        XCTAssertTrue(item.isFinished)
        let bodies = transport.finalizeBodies()
        XCTAssertNil(bodies[0]["title"], "no placeholder title — the server must stay 'Untitled' to auto-title")
        XCTAssertNotNil(bodies[1]["transcript"])
        XCTAssertNil(bodies[1]["title"])
        XCTAssertEqual(server.title, "Cloud title")
        XCTAssertTrue(services.titleCalls.isEmpty, "the app must not duplicate cloud titling")
    }

    // Cloud transcription + cloud title: the backend does everything.
    func testCloudTranscriptionCloudTitle() async {
        let (item, transport, server, services) = await run(.init(transcription: .cloud, titleProvider: .hearMeOut))
        XCTAssertTrue(item.isFinished)
        let bodies = transport.finalizeBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["transcribe"] as? Bool, false)
        XCTAssertEqual(bodies[1]["transcribe"] as? Bool, true)
        XCTAssertEqual(services.transcribeCalls, 0)
        XCTAssertEqual(item.transcript, "cloud transcript text")
        XCTAssertEqual(server.title, "Cloud title")
    }

    // Cloud transcription + Apple title: wait for the transcript, then send the local title.
    func testCloudTranscriptionAppleTitle() async {
        let (item, transport, server, services) = await run(.init(transcription: .cloud, titleProvider: .appleIntelligence))
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(services.titleCalls.first?.0, "cloud transcript text")
        let last = transport.finalizeBodies().last!
        XCTAssertEqual(last["title"] as? String, "Feedback on Sam's essay")
        XCTAssertEqual(last["titleIsAi"] as? Bool, true)
        XCTAssertNil(last["transcript"], "the cloud transcript is not re-sent")
        XCTAssertEqual(server.title, "Feedback on Sam's essay")
    }

    // No transcription: one finalise with transcribe:false and a default title.
    func testNoTranscription() async {
        let (item, transport, _, services) = await run(.init(transcription: .none, titleProvider: .hearMeOut))
        XCTAssertTrue(item.isFinished)
        let bodies = transport.finalizeBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0]["transcribe"] as? Bool, false)
        XCTAssertNil(bodies[0]["transcript"])
        XCTAssertNotNil(bodies[0]["title"])
        XCTAssertEqual(services.transcribeCalls, 0)
        XCTAssertTrue(services.titleCalls.isEmpty)
    }

    // Manual title is sent as-is with titleIsAi:false and never overwritten.
    func testManualTitleWins() async {
        let (item, transport, server, services) = await run(.init(transcription: .local, titleProvider: .appleIntelligence), userTitle: "Year 11 feedback")
        XCTAssertTrue(item.isFinished)
        XCTAssertTrue(services.titleCalls.isEmpty, "a typed title means no generation")
        for b in transport.finalizeBodies() where b["title"] != nil {
            XCTAssertEqual(b["title"] as? String, "Year 11 feedback")
            XCTAssertEqual(b["titleIsAi"] as? Bool, false)
        }
        XCTAssertEqual(server.title, "Year 11 feedback")
    }

    func testPlaceholderTitleIsTreatedAsMissing() {
        let s = MockServices()
        let item = s.makeItem(prefs: .init(transcription: .local, titleProvider: .hearMeOut), userTitle: "Untitled recording")
        XCTAssertNil(item.userTitle)
        XCTAssertNil(Pipeline.fastFinalizeRequest(for: item).title)
    }

    func testTitleFailurePreservesTranscriptAndDoesNotFallBackToCloud() async {
        let (item, transport, server, _) = await run(.init(transcription: .local, titleProvider: .openAI)) { s, _ in
            s.titleResult = .failure(TitleError("Your OpenAI quota is used up.", transient: false))
        }
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(item.titleStage, .failed)
        let last = transport.finalizeBodies().last!
        XCTAssertNotNil(last["transcript"], "transcript still attached")
        XCTAssertNil(last["title"])
        XCTAssertNotEqual(server.title, "Cloud title", "no silent fallback to Hear Me Out titling")
        XCTAssertTrue(item.lastError?.contains("quota") == true)
    }

    func testLocalTranscriptionFailureKeepsShareLink() async {
        let (item, _, _, _) = await run(.init(transcription: .local, titleProvider: .appleIntelligence)) { s, _ in
            s.transcriptResult = .failure(TranscriptionError("This format can't be decoded on this Mac."))
        }
        XCTAssertTrue(item.isFinished)
        XCTAssertNotNil(item.share)
        XCTAssertEqual(item.transcriptStage, .failed)
        XCTAssertEqual(item.titleStage, .notNeeded)
    }

    func testNoSpeechNeverTitles() async {
        let (item, _, _, services) = await run(.init(transcription: .local, titleProvider: .appleIntelligence)) { s, _ in
            s.transcriptResult = .success("   ")
        }
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(item.transcript, "[No speech detected]")
        XCTAssertTrue(services.titleCalls.isEmpty)
    }

    func testExpiredUploadTokenIsReissuedWithoutDuplicate() async {
        let (item, transport, server, services) = await run(.init(transcription: .none, titleProvider: .manual)) { s, _ in
            s.uploadErrors = [UploadError.tokenRejected]
        }
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(server.reissueCount, 1)
        XCTAssertEqual(transport.calls.filter { $0.path == "/uploads" }.count, 1, "never create a second recording")
        XCTAssertEqual(services.uploads.last?.1.headers["Authorization"], "Bearer tok2")
    }

    func testTransientUploadFailureRetries() async {
        let (item, transport, _, _) = await run(.init(transcription: .none, titleProvider: .manual)) { s, _ in
            s.uploadErrors = [UploadError.network("offline"), UploadError.server(503)]
        }
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(transport.calls.filter { $0.path == "/uploads" }.count, 1)
    }

    func testMissingFileOnServerReuploads() async {
        let (item, _, server, services) = await run(.init(transcription: .none, titleProvider: .manual)) { _, srv in
            srv.failNextFinalizeWith = 400
        }
        XCTAssertTrue(item.isFinished)
        XCTAssertEqual(services.uploads.count, 2)
        XCTAssertEqual(server.reissueCount, 1)
    }

    func testUnauthorisedPausesAccountAndKeepsWork() async {
        let services = MockServices()
        let transport = MockTransport { _, _ in (401, ["error": "unauthorised"]) }
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: transport)
        let engine = ProcessingEngine(retry: .immediate)
        var failed: [String] = []
        engine.onAuthFailure = { failed.append($0) }
        engine.services = services
        let item = services.makeItem(prefs: .init(transcription: .local, titleProvider: .appleIntelligence))
        engine.add(item)
        await waitUntil { !failed.isEmpty && engine.item(item.id)?.titleStage == .done }
        XCTAssertEqual(failed.first, "acc-a")
        XCTAssertTrue(engine.pausedAccounts.contains("acc-a"))
        let it = engine.item(item.id)!
        XCTAssertEqual(it.upload, .pending)
        XCTAssertEqual(it.transcriptStage, .done, "local work continues while the account is paused")
        XCTAssertFalse(it.needsAttention)
    }

    func testAccountIsolationUsesEachItemsOwnKey() async {
        let services = MockServices()
        let serverA = FakeServer(recordingId: "rec-a")
        let serverB = FakeServer(recordingId: "rec-b")
        let tA = MockTransport(handler: serverA.handle)
        let tB = MockTransport(handler: serverB.handle)
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: tA)
        services.clients["acc-b"] = HMOClient(apiKey: "hmo_b", transport: tB)
        let engine = ProcessingEngine(retry: .immediate)
        engine.services = services
        let a = services.makeItem(account: "acc-a", prefs: .init(transcription: .none, titleProvider: .manual))
        let b = services.makeItem(account: "acc-b", prefs: .init(transcription: .none, titleProvider: .manual))
        engine.add(a)
        engine.add(b)
        await waitUntil { engine.item(a.id)?.isFinished == true && engine.item(b.id)?.isFinished == true }
        XCTAssertTrue(tA.calls.allSatisfy { $0.auth == "Bearer hmo_a" })
        XCTAssertTrue(tB.calls.allSatisfy { $0.auth == "Bearer hmo_b" })
        XCTAssertEqual(engine.item(a.id)?.recordingId, "rec-a")
        XCTAssertEqual(engine.item(b.id)?.recordingId, "rec-b")
    }

    func testReassignOnlyBeforeServerRecordingExists() async {
        let services = MockServices()
        let engine = ProcessingEngine(retry: .immediate)
        engine.services = services   // no clients → nothing uploads
        let item = services.makeItem(prefs: .init(transcription: .none, titleProvider: .manual))
        engine.add(item)
        XCTAssertTrue(engine.reassign(item.id, to: "acc-b", preferences: .init(transcription: .none, titleProvider: .manual)))
        XCTAssertEqual(engine.item(item.id)?.accountId, "acc-b")
        engine.update(item.id) { $0.recordingId = "rec"; $0.upload = .ticketed }
        XCTAssertFalse(engine.reassign(item.id, to: "acc-a", preferences: .init()))
        XCTAssertEqual(engine.item(item.id)?.accountId, "acc-b")
    }

    func testTooLongIsRejectedLocally() async {
        let services = MockServices()
        let server = FakeServer()
        let transport = MockTransport(handler: server.handle)
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: transport)
        let engine = ProcessingEngine(retry: .immediate)
        engine.services = services
        let item = services.makeItem(prefs: .init(transcription: .none, titleProvider: .manual), duration: 903)
        engine.add(item)
        await waitUntil { engine.item(item.id)?.needsAttention == true }
        XCTAssertTrue(engine.item(item.id)!.lastError!.contains("15-minute"))
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testRecoverAfterLaunchResetsRunningStages() {
        let s = MockServices()
        var item = s.makeItem(prefs: .init(transcription: .local, titleProvider: .openAI))
        item.transcriptStage = .running
        item.syncStage = .running
        let engine = ProcessingEngine(items: [item])
        XCTAssertEqual(engine.items[0].transcriptStage, .pending)
        XCTAssertEqual(engine.items[0].syncStage, .pending)
    }

    func testOfflineDefersNetworkButTranscribesLocally() async {
        let services = MockServices()
        let server = FakeServer()
        let transport = MockTransport(handler: server.handle)
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: transport)
        let engine = ProcessingEngine(retry: .immediate)
        engine.isOnline = false
        engine.services = services
        let item = services.makeItem(prefs: .init(transcription: .local, titleProvider: .appleIntelligence))
        engine.add(item)
        await waitUntil { engine.item(item.id)?.titleStage == .done }
        XCTAssertTrue(transport.calls.isEmpty)
        engine.isOnline = true
        await waitUntil { engine.item(item.id)?.isFinished == true }
        XCTAssertTrue(engine.item(item.id)!.isFinished)
    }

    func testRenameAfterFinishSendsTitleOnly() async {
        let services = MockServices()
        let server = FakeServer()
        let transport = MockTransport(handler: server.handle)
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: transport)
        let engine = ProcessingEngine(retry: .immediate)
        engine.services = services
        let item = services.makeItem(prefs: .init(transcription: .none, titleProvider: .manual))
        engine.add(item)
        await waitUntil { engine.item(item.id)?.isFinished == true }
        engine.rename(item.id, to: "Parents' evening notes")
        await waitUntil { engine.item(item.id)?.isFinished == true && server.title == "Parents' evening notes" }
        XCTAssertEqual(server.title, "Parents' evening notes")
        XCTAssertEqual(transport.finalizeBodies().last?["titleIsAi"] as? Bool, false)
    }

    func testSwitchToCloudAfterLocalFailure() async {
        let services = MockServices()
        services.transcriptResult = .failure(TranscriptionError("Can't decode WebM locally."))
        let server = FakeServer()
        let transport = MockTransport(handler: server.handle)
        services.clients["acc-a"] = HMOClient(apiKey: "hmo_a", transport: transport)
        let engine = ProcessingEngine(retry: .immediate)
        engine.cloudPollInterval = 0.01
        engine.services = services
        let item = services.makeItem(prefs: .init(transcription: .local, titleProvider: .hearMeOut))
        engine.add(item)
        await waitUntil { engine.item(item.id)?.isFinished == true }
        engine.switchToCloudTranscription(item.id)
        await waitUntil { engine.item(item.id)?.isFinished == true && engine.item(item.id)?.transcriptStage == .done }
        XCTAssertEqual(engine.item(item.id)?.transcript, "cloud transcript text")
        XCTAssertEqual(transport.finalizeBodies().last?["transcribe"] as? Bool, true)
    }
}
