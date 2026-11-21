import XCTest
@testable import HearMeOutCore

final class PKCETests: XCTestCase {
    func testRFC7636Vector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedValuesAreURLSafeAndLongEnough() {
        let p = PKCE.generate()
        XCTAssertGreaterThanOrEqual(p.verifier.count, 43)
        XCTAssertLessThanOrEqual(p.verifier.count, 128)
        XCTAssertNil(p.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(PKCE.generate().state, p.state)
    }

    func testConnectURL() {
        let p = PKCE(verifier: "v".padding(toLength: 50, withPad: "v", startingAt: 0), state: "state123")
        let u = NativeAuthURLs.connectURL(pkce: p, deviceName: "George's MacBook Pro")
        let c = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "hearmeout.george-hall.uk")
        XCTAssertEqual(c.path, "/native/connect")
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], p.challenge)
        XCTAssertEqual(q["redirect_uri"], "hearmeout://auth/callback")
        XCTAssertEqual(q["state"], "state123")
        XCTAssertNil(q["code_verifier"], "the verifier never leaves the app in the URL")
    }

    func testCallbackParsing() {
        XCTAssertEqual(NativeAuthURLs.parseCallback(URL(string: "hearmeout://auth/callback?code=abc&state=s1")!, expectedState: "s1"), .code("abc"))
        XCTAssertEqual(NativeAuthURLs.parseCallback(URL(string: "hearmeout://auth/callback#code=abc&state=s1")!, expectedState: "s1"), .code("abc"))
        XCTAssertEqual(NativeAuthURLs.parseCallback(URL(string: "hearmeout://auth/callback?error=access_denied&state=s1")!, expectedState: "s1"), .denied)
        if case .error = NativeAuthURLs.parseCallback(URL(string: "hearmeout://auth/callback?code=abc&state=WRONG")!, expectedState: "s1") {} else { XCTFail("state mismatch must fail") }
        if case .error = NativeAuthURLs.parseCallback(URL(string: "evil://auth/callback?code=abc&state=s1")!, expectedState: "s1") {} else { XCTFail("scheme must be checked") }
    }
}

final class ShareTests: XCTestCase {
    let links = ShareLinks(shareUrl: "https://hearmeout.george-hall.uk/s/3fa85f64c9d44e599e8b7c02b8d0e123",
                           embedUrl: "https://hearmeout.george-hall.uk/embed/3fa85f64c9d44e599e8b7c02b8d0e123",
                           embedCode: "<iframe src=\"x\" height=\"152\"></iframe>")

    func testMessageNeverIncludesTitle() {
        XCTAssertEqual(ShareText.payload(.message, links: links).plainText,
                       "Hey, I've recorded you a voice memo. Click here to listen: https://hearmeout.george-hall.uk/s/3fa85f64c9d44e599e8b7c02b8d0e123")
    }

    func testGmailHasHTMLAndPlainText() {
        let p = ShareText.payload(.gmail, links: links)
        XCTAssertTrue(p.html!.contains("https://hearmeout.george-hall.uk/api/public/card/3fa85f64c9d44e599e8b7c02b8d0e123"))
        XCTAssertTrue(p.html!.contains("width=\"480\""))
        XCTAssertFalse(p.html!.contains("<iframe"))
        XCTAssertTrue(p.plainText.hasPrefix(ShareText.messagePrefix))
    }

    func testEmbedAndLink() {
        XCTAssertEqual(ShareText.payload(.embed, links: links).plainText, links.embedCode)
        XCTAssertEqual(ShareText.payload(.link, links: links).plainText, links.shareUrl)
        XCTAssertNil(ShareText.shareToken(from: "https://evil.example/x/abc"))
    }
}

final class TitleSanitiserTests: XCTestCase {
    func testCleansDecoration() {
        XCTAssertEqual(TitleSanitiser.clean("Title: \"Feedback on Sam's essay.\""), "Feedback on Sam's essay")
        XCTAssertEqual(TitleSanitiser.clean("**Year 11 revision plan**\nThis note covers…"), "Year 11 revision plan")
        XCTAssertEqual(TitleSanitiser.clean("  “Parents’ evening follow-up”  "), "Parents’ evening follow-up")
    }

    func testRejectsGenericAndParagraphs() {
        XCTAssertNil(TitleSanitiser.clean("Voice note"))
        XCTAssertNil(TitleSanitiser.clean(""))
        XCTAssertNil(TitleSanitiser.clean("In this recording the speaker talks about many different things including the weather and the trip"))
    }

    func testTruncatesAtWordBoundary() {
        let t = TitleSanitiser.clean(String(repeating: "Supercalifragilistic ", count: 6))!
        XCTAssertLessThanOrEqual(t.count, TitleSanitiser.maxLength)
        XCTAssertFalse(t.hasSuffix(" "))
    }
}

final class LimitsTests: XCTestCase {
    func testDuration() {
        XCTAssertTrue(HMOLimits.durationIsAcceptable(900))
        XCTAssertTrue(HMOLimits.durationIsAcceptable(901.9))
        XCTAssertFalse(HMOLimits.durationIsAcceptable(902.5))
        XCTAssertFalse(HMOLimits.durationIsAcceptable(0))
    }

    func testRecordedAtFormatHasTimezone() {
        let s = RecordedAt.string(from: Date(timeIntervalSince1970: 1_763_631_000))
        XCTAssertEqual(s, "2025-11-20T09:30:00Z")
    }

    func testRecordedAtValidation() {
        let now = Date()
        XCTAssertNil(RecordedAt.validated(now.addingTimeInterval(600), now: now))
        XCTAssertNotNil(RecordedAt.validated(now.addingTimeInterval(120), now: now))
        XCTAssertNil(RecordedAt.validated(Date(timeIntervalSince1970: 900_000_000), now: now))
    }

    func testFormats() {
        XCTAssertTrue(AudioFormat.isBackendSupported("M4A"))
        XCTAssertFalse(AudioFormat.isBackendSupported("aiff"))
        XCTAssertEqual(AudioFormat.mimeType(forExtension: "mp3"), "audio/mpeg")
        XCTAssertFalse(AudioFormat.isLocallyDecodable("webm"))
    }

    func testISODateParsing() {
        XCTAssertNotNil(ISODate.parse("2026-11-20T09:30:00.000Z"))
        XCTAssertNotNil(ISODate.parse("2026-11-20T09:30:00+00:00"))
        XCTAssertNil(ISODate.parse("yesterday"))
    }

    func testProvisionalTitleIsBritish() {
        let t = ProvisionalTitle.make(for: Date(timeIntervalSince1970: 1_763_631_000), timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(t, "Voice note · 20 Nov 2025, 09:30")
        XCTAssertTrue(ProvisionalTitle.isProvisional(t))
    }
}

final class APIDecodingTests: XCTestCase {
    func testLenientNumbersAndMissingFields() throws {
        let json = #"{"items":[{"id":"1","title":"A","duration_seconds":"73.4","size_bytes":482113,"status":"ready","play_count":3,"recorded_at":"2026-11-20T09:30:00.000Z","shareUrl":"https://x/s/abc"},{"id":"2","title":"B"}]}"#
        let list = try JSONDecoder().decode(RecordingList.self, from: Data(json.utf8))
        XCTAssertEqual(list.items[0].duration_seconds, 73.4)
        XCTAssertEqual(list.items[0].plays, 3)
        XCTAssertNotNil(list.items[0].recordedDate)
        XCTAssertNil(list.items[1].duration_seconds)
    }

    func testUploadTicketNormalisesBothShapes() throws {
        let a = try JSONDecoder().decode(RawUploadTicket.self, from: Data(#"{"recordingId":"r","key":"k","url":"https://m/hmo/upload?key=k","token":"t","exp":1763700000,"method":"PUT","headers":{"Authorization":"Bearer t"}}"#.utf8)).normalised()
        XCTAssertEqual(a.headers["Authorization"], "Bearer t")
        let b = try JSONDecoder().decode(RawUploadTicket.self, from: Data(#"{"recordingId":"r","uploadUrl":"https://m/hmo/upload?key=k","token":"t","exp":1763700000}"#.utf8)).normalised()
        XCTAssertEqual(b.headers["Authorization"], "Bearer t")
        XCTAssertEqual(b.method, "PUT")
    }

    func testFinalizeRequestOmitsNilFields() throws {
        let data = try JSONEncoder().encode(FinalizeRequest(transcript: "x", transcribe: false))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["title"], "a missing title must stay missing")
        XCTAssertEqual(obj.count, 2)
    }

    func testErrorMapping() async {
        for (status, expected) in [(401, HMOError.unauthorised), (404, .notFound("x")), (409, .conflict("x")), (429, .rateLimited("x")), (503, .http(503, "x"))] {
            let c = HMOClient(apiKey: "hmo_k", transport: MockTransport { _, _ in (status, ["error": "x"]) })
            do { _ = try await c.listRecordings(); XCTFail() } catch let e as HMOError { XCTAssertEqual(e, expected) } catch { XCTFail("\(error)") }
        }
        let offline = HMOClient(apiKey: "hmo_k", transport: MockTransport { _, _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.listRecordings(); XCTFail() } catch let e as HMOError { XCTAssertTrue(e.isTransient) } catch { XCTFail() }
    }

    func testBearerAndPaths() async throws {
        let t = MockTransport { _, _ in (200, ["items": []]) }
        _ = try await HMOClient(apiKey: "hmo_abc", transport: t).listRecordings()
        XCTAssertEqual(t.calls[0].auth, "Bearer hmo_abc")
        XCTAssertEqual(t.calls[0].path, "/recordings")
    }
}

final class StoreTests: XCTestCase {
    func testAtomicSaveAndBackupRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONStore<[String]>(url: dir.appendingPathComponent("q.json"))
        try store.save(["a"])
        try store.save(["a", "b"])
        XCTAssertEqual(store.load(), ["a", "b"])
        try Data("{corrupt".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), ["a"], "falls back to the previous good copy")
        let perms = try FileManager.default.attributesOfItem(atPath: store.backupURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    @MainActor
    func testQueueItemRoundTrip() throws {
        let s = MockServices()
        let item = s.makeItem(prefs: .init(transcription: .local, titleProvider: .openAI))
        let url = s.dir.appendingPathComponent("queue.json")
        try JSONStore<[QueueItem]>(url: url).save([item])
        XCTAssertEqual(JSONStore<[QueueItem]>(url: url).load(), [item])
    }
}

final class ModelDiscoveryTests: XCTestCase {
    func makeWhisperKitModel(at base: URL, variant: String, tokenizer: Bool = true) throws -> URL {
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
        for b in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(b), withIntermediateDirectories: true)
            try Data(count: 128).write(to: folder.appendingPathComponent(b).appendingPathComponent("weights.bin"))
        }
        if tokenizer {
            let t = base.appendingPathComponent("models/openai/whisper-large-v3")
            try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: t.appendingPathComponent("tokenizer.json"))
        }
        return folder
    }

    func testFindsLetsMeetLayoutAndTokenizer() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = ModelDiscovery.letsMeetModelBases(home: home)[0]
        XCTAssertTrue(base.path.hasSuffix("Library/Containers/com.georgehalltuition.lessonnotes/Data/Library/Application Support/LessonNotes/WhisperModels"))
        let folder = try makeWhisperKitModel(at: base, variant: "openai_whisper-large-v3-v20240930_turbo_632MB")
        let found = ModelDiscovery.scan(base, origin: .sharedFromLetsMeet)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].format, .whisperKitCoreML)
        XCTAssertEqual(found[0].folder.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(found[0].tokenizerBase?.standardizedFileURL.path, base.standardizedFileURL.path)
        XCTAssertTrue(ModelDiscovery.hasTokenizer(base: base, variant: found[0].name))
        XCTAssertGreaterThan(found[0].sizeBytes, 0)
    }

    func testDetectsIncompatibleGGML() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("ggml-large-v3.bin"))
        XCTAssertEqual(ModelDiscovery.format(of: dir), .ggml)
        XCTAssertFalse(ModelDiscovery.format(of: dir).isCompatible)
    }

    func testScanningDoesNotModifyFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = try makeWhisperKitModel(at: base, variant: "openai_whisper-small.en")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        _ = ModelDiscovery.scan(base, origin: .userFolder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
    }

    func testFriendlyNames() {
        XCTAssertEqual(ModelNames.friendly("openai_whisper-large-v3-v20240930_turbo_632MB"), "Large v3 Turbo · 632 MB")
        XCTAssertEqual(ModelNames.friendly("openai_whisper-small.en"), "Small.en")
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    func testMergeAndFilter() {
        let s = MockServices()
        var local = s.makeItem(prefs: .init(transcription: .local, titleProvider: .hearMeOut))
        local.recordingId = "r1"
        let pending = s.makeItem(prefs: .init(transcription: .none, titleProvider: .manual))
        var r1 = RemoteRecording(id: "r1", title: "Essay feedback", duration: 60, transcriptionStatus: "done", playCount: 2, recordedAt: "2026-11-20T09:30:00Z", shareUrl: "https://x/s/a")
        r1.transcript = "the quick brown fox"
        let r2 = RemoteRecording(id: "r2", title: "Maths plan", duration: 120, transcriptionStatus: "none", playCount: 0, recordedAt: "2026-11-19T09:30:00Z", shareUrl: "https://x/s/b")
        let merged = LibraryQuery.merge(remote: [r1, r2], local: [local, pending])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(LibraryQuery.apply(merged, search: "fox", filter: .all, sort: .newest).map(\.id), ["r1"])
        XCTAssertEqual(LibraryQuery.apply(merged, search: "", filter: .shared, sort: .newest).map(\.id), ["r1"])
        XCTAssertEqual(LibraryQuery.apply(merged, search: "", filter: .all, sort: .longest).first?.id, "r2")
        XCTAssertTrue(LibraryQuery.apply(merged, search: "", filter: .processing, sort: .newest).contains { $0.local?.id == pending.id })
    }

    func testAccountInitials() {
        let a = Account(id: "1", userId: "1", email: "ghall@example.com", displayName: "George Hall", avatarURL: nil, authMethod: .google, keyPrefix: nil, themeId: "botanical")
        XCTAssertEqual(a.initials, "GH")
        XCTAssertEqual(a.title, "George Hall")
        let b = Account(id: "2", userId: nil, email: "tutor@example.com", displayName: nil, avatarURL: nil, authMethod: .apiKey, keyPrefix: "hmo_ab12", themeId: "x")
        XCTAssertEqual(b.initials, "T")
    }
}
