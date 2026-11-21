import Foundation
import HearMeOutCore

/// Fictional sample content for screenshots and UI tests (HMO_DEMO=…). It runs in a temporary folder,
/// never reads or writes real accounts, keys or recordings, and makes no network requests.
enum DemoData {
    @MainActor
    static func install(_ scenario: DemoScenario, into model: AppModel) {
        let themeOverride = ProcessInfo.processInfo.environment["HMO_THEME"]
        let accounts = [
            Account(id: "demo-personal", userId: "demo-personal", email: "alex@example.com", displayName: "Alex Morgan", avatarURL: nil,
                    nickname: "Personal", authMethod: .google, keyPrefix: nil, themeId: themeOverride ?? "botanical",
                    preferences: .init(transcription: .local, titleProvider: .appleIntelligence)),
            Account(id: "demo-work", userId: "demo-work", email: "alex.morgan@example.org", displayName: "Alex Morgan", avatarURL: nil,
                    nickname: "Work", authMethod: .google, keyPrefix: nil, themeId: "coastal",
                    preferences: .init(transcription: .local, titleProvider: .hearMeOut)),
            Account(id: "demo-tutoring", userId: "demo-tutoring", email: "tutor@example.net", displayName: "Alex Morgan", avatarURL: nil,
                    nickname: "Tutoring", authMethod: .apiKey, keyPrefix: "hmo_demo", themeId: "midnight",
                    preferences: .init(transcription: .cloud, titleProvider: .hearMeOut)),
        ]
        let iso = ISO8601DateFormatter()
        func ago(_ h: Double) -> String { iso.string(from: Date().addingTimeInterval(-h * 3600)) }
        func link(_ n: Int) -> (String, String, String) {
            let t = String(repeating: "\(n)", count: 4) + "demo0000share0000token00"
            return ("https://hearmeout.george-hall.uk/s/\(t)", "https://hearmeout.george-hall.uk/embed/\(t)", "<iframe src=\"https://hearmeout.george-hall.uk/embed/\(t)\" height=\"152\"></iframe>")
        }
        let titles: [(String, Double, Double, Double, String)] = [
            ("Feedback on Sam's Year 11 essay", 186, 0.6, 4, "done"),
            ("Plan for Thursday's revision session", 94, 5, 0, "done"),
            ("Parents' evening follow-up notes", 412, 26, 2, "done"),
            ("Ideas for the spring newsletter", 233, 50, 1, "processing"),
            ("Mock exam timings and logistics", 77, 75, 6, "done"),
            ("Reply to Priya about the trip", 128, 120, 3, "done"),
            ("Weekly catch-up summary", 540, 170, 0, "none"),
        ]
        var recs: [RemoteRecording] = []
        for (i, t) in titles.enumerated() {
            let l = link(i + 1)
            var r = RemoteRecording(id: "demo-\(i)", title: t.0, duration: t.1, transcriptionStatus: t.4, playCount: t.3,
                                    createdAt: ago(t.2), recordedAt: ago(t.2), shareUrl: l.0, embedUrl: l.1, embedCode: l.2)
            if t.4 == "done" {
                r.transcript = "Hi Sam, I've had a really good read of your essay and I wanted to talk you through a few thoughts. Your opening paragraph is strong — the quotation you chose sets up the argument nicely. Where I'd like you to push further is in the third section, where the analysis starts to summarise rather than explain…"
            }
            if t.3 > 0 { r.first_played_at = ago(t.2 - 0.3); r.last_played_at = ago(max(0, t.2 - 1)) }
            recs.append(r)
        }
        model.demoSet(accounts: accounts, library: ["demo-personal": recs, "demo-work": Array(recs.prefix(3)), "demo-tutoring": Array(recs.suffix(4))])
        model.settings.hasCompletedOnboarding = scenario != .onboarding
        model.showOnboarding = scenario == .onboarding

        // Demo mode never runs the pipeline.
        model.engine.services = nil
        switch scenario {
        case .library:
            model.tab = .library
            model.selectedEntryId = "demo-0"
        case .activity:
            model.tab = .activity
            addQueueSamples(model)
        case .settings:
            model.tab = .settings
            model.settingsSection = .transcription
        case .themes:
            model.tab = .settings
            model.settingsSection = .appearance
        case .accounts:
            model.tab = .create
            model.showAccountSwitcher = true
        case .create, .menubar:
            model.tab = .create
            addQueueSamples(model)
        case .recording:
            model.tab = .create
            model.recorder.demoSimulateRecording(accountId: "demo-personal")
        case .review, .onboarding:
            model.tab = .create
        }
    }

    @MainActor
    private static func addQueueSamples(_ model: AppModel) {
        var a = QueueItem(accountId: "demo-personal", recordedAt: Date().addingTimeInterval(-120), durationSeconds: 96, sizeBytes: 1_200_000,
                          fileExtension: "m4a", originalFilename: nil, audioFileName: "demo-a.m4a", source: .recording, userTitle: nil,
                          preferences: .init(transcription: .local, titleProvider: .appleIntelligence))
        a.upload = .ready
        a.recordingId = "demo-q1"
        a.share = ShareLinks(shareUrl: "https://hearmeout.george-hall.uk/s/q1demo0000share0000token0000", embedUrl: "https://hearmeout.george-hall.uk/embed/q1", embedCode: "<iframe></iframe>")
        a.transcriptStage = .running
        var b = QueueItem(accountId: "demo-personal", recordedAt: Date().addingTimeInterval(-40), durationSeconds: 212, sizeBytes: 3_300_000,
                          fileExtension: "m4a", originalFilename: nil, audioFileName: "demo-b.m4a", source: .recording, userTitle: "Year 9 homework walkthrough",
                          preferences: .init(transcription: .local, titleProvider: .hearMeOut))
        b.upload = .ticketed
        b.recordingId = "demo-q2"
        var c = QueueItem(accountId: "demo-work", recordedAt: Date().addingTimeInterval(-3600), durationSeconds: 61, sizeBytes: 900_000,
                          fileExtension: "m4a", originalFilename: nil, audioFileName: "demo-c.m4a", source: .recording, userTitle: nil,
                          preferences: .init(transcription: .local, titleProvider: .openAI))
        c.upload = .ready
        c.recordingId = "demo-q3"
        c.share = ShareLinks(shareUrl: "https://hearmeout.george-hall.uk/s/q3demo0000share0000token0000", embedUrl: "https://hearmeout.george-hall.uk/embed/q3", embedCode: "<iframe></iframe>")
        c.transcriptStage = .done
        c.transcript = "Quick update on the budget."
        c.titleStage = .failed
        c.syncStage = .done
        c.finishedAt = Date()
        c.lastError = "Title not generated: Your OpenAI account has run out of credit. Top up, then choose Retry title."
        // Order matters: newest first.
        for item in [c, a, b] { model.engine.add(item) }
    }
}
