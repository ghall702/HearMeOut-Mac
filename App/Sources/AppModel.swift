import SwiftUI
import AppKit
import Combine
import CryptoKit
import HearMeOutCore

enum AppTab: String, CaseIterable, Identifiable {
    case create, library, activity, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .create: return "Create"
        case .library: return "Library"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .create: return "mic.fill"
        case .library: return "square.stack.fill"
        case .activity: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts, appearance, recording, transcription, titles, storage, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accounts: return "Accounts"
        case .appearance: return "Appearance"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .titles: return "AI Titles"
        case .storage: return "Storage & Processing"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .accounts: return "person.2.fill"
        case .appearance: return "paintpalette.fill"
        case .recording: return "mic.fill"
        case .transcription: return "text.bubble.fill"
        case .titles: return "sparkles"
        case .storage: return "externaldrive.fill"
        case .about: return "info.circle.fill"
        }
    }
}

/// App-wide preferences (per-account choices live on each Account).
struct AppSettings: Codable, Equatable {
    var appearance: AppearanceChoice = .themeDefault
    var useGlobalTheme = false
    var globalThemeId = ThemeCatalog.defaultId
    var recordingQuality: RecordingQuality = .high
    var showMenuBar = true
    var copyLinkWhenReady = false
    var preferredShareFormat: ShareFormat = .link
    var openAIModel = OpenAITitleGenerator.preferred[0]
    var defaultPreferences = ProcessingPreferences(transcription: .local, titleProvider: .hearMeOut)
    var recordShortcut: Shortcut? = .defaultRecord
    var openShortcut: Shortcut? = .defaultOpen
    var copyShortcut: Shortcut? = .defaultCopyLink
    var removeUploadedAudioAfterDays: Int = 30
    var hasCompletedOnboarding = false
    var defaultAccountId: String?
    var decorations = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appearance = (try? c.decode(AppearanceChoice.self, forKey: .appearance)) ?? d.appearance
        useGlobalTheme = (try? c.decode(Bool.self, forKey: .useGlobalTheme)) ?? d.useGlobalTheme
        globalThemeId = (try? c.decode(String.self, forKey: .globalThemeId)) ?? d.globalThemeId
        recordingQuality = (try? c.decode(RecordingQuality.self, forKey: .recordingQuality)) ?? d.recordingQuality
        showMenuBar = (try? c.decode(Bool.self, forKey: .showMenuBar)) ?? d.showMenuBar
        copyLinkWhenReady = (try? c.decode(Bool.self, forKey: .copyLinkWhenReady)) ?? d.copyLinkWhenReady
        preferredShareFormat = (try? c.decode(ShareFormat.self, forKey: .preferredShareFormat)) ?? d.preferredShareFormat
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? d.openAIModel
        defaultPreferences = (try? c.decode(ProcessingPreferences.self, forKey: .defaultPreferences)) ?? d.defaultPreferences
        recordShortcut = try? c.decode(Shortcut.self, forKey: .recordShortcut)
        openShortcut = try? c.decode(Shortcut.self, forKey: .openShortcut)
        copyShortcut = try? c.decode(Shortcut.self, forKey: .copyShortcut)
        removeUploadedAudioAfterDays = (try? c.decode(Int.self, forKey: .removeUploadedAudioAfterDays)) ?? d.removeUploadedAudioAfterDays
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        defaultAccountId = try? c.decode(String.self, forKey: .defaultAccountId)
        decorations = (try? c.decode(Bool.self, forKey: .decorations)) ?? d.decorations
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String = "checkmark.circle.fill"
    var isError = false
}

@MainActor
final class AppModel: ObservableObject {
    /// SwiftUI may initialise the App struct more than once; the model (and its queue) must exist only once.
    static var instance: AppModel?
    static func shared(demo: DemoScenario?) -> AppModel {
        if let m = instance { return m }
        let m = AppModel(demo: demo)
        instance = m
        return m
    }

    // Accounts
    @Published private(set) var accounts: [Account] = []
    @Published var activeAccountId: String?
    // Navigation
    @Published var tab: AppTab = .create
    @Published var settingsSection: SettingsSection = .accounts
    @Published var selectedEntryId: String?
    @Published var showAccountSwitcher = false
    @Published var showOnboarding = false
    // Appearance
    @Published var settings = AppSettings() { didSet { if settings != oldValue { saveSettings(); settingsChanged(oldValue) } } }
    @Published var previewThemeId: String?
    /// The macOS appearance (independent of the scheme the app forces on its own windows).
    var systemScheme: ColorScheme {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
    // Library
    @Published private(set) var library: [String: [RemoteRecording]] = [:]
    @Published private(set) var libraryLoading: Set<String> = []
    @Published private(set) var libraryError: [String: String] = [:]
    @Published private(set) var details: [String: RemoteRecording] = [:]
    @Published private(set) var playbackAvailable: Bool? = nil
    // Feedback
    @Published var toast: Toast?
    @Published private(set) var signInInProgress = false
    @Published var signInError: String?
    @Published private(set) var nativeSignInAvailable: Bool?

    let engine: ProcessingEngine
    let services: AppServices
    let whisper: WhisperEngine
    let models: ModelLibrary
    let devices: AudioDeviceManager
    let recorder: RecordingController
    let avatars = AvatarCache()
    let connectivity = Connectivity()
    let libraryPlayer = AudioPlayer()
    let isDemo: Bool

    private var keyCache: [String: String] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var toastTask: Task<Void, Never>?

    init(demo: DemoScenario? = nil) {
        let demoMode = demo != nil
        isDemo = demoMode
        if demoMode {
            AppPaths.demoRoot = FileManager.default.temporaryDirectory.appendingPathComponent("HearMeOutDemo-\(UUID().uuidString)")
        }
        let models = ModelLibrary()
        self.models = models
        let whisper = WhisperEngine { await MainActor.run { models.resolvedForTranscription() } }
        self.whisper = whisper
        self.services = AppServices(whisper: whisper)
        self.devices = AudioDeviceManager()
        self.recorder = RecordingController()

        let stored = demoMode ? [] : (JSONStore<[QueueItem]>(url: AppPaths.queueFile).load() ?? [])
        self.engine = ProcessingEngine(items: stored)
        if !isDemo {
            accounts = JSONStore<[Account]>(url: AppPaths.accountsFile).load() ?? []
            settings = JSONStore<AppSettings>(url: AppPaths.settingsFile).load() ?? AppSettings()
            for a in accounts { library[a.id] = JSONStore<[RemoteRecording]>(url: libraryFile(a.id)).load() }
        }
        activeAccountId = settings.defaultAccountId.flatMap { id in accounts.first { $0.id == id }?.id } ?? accounts.first?.id

        services.model = self
        engine.services = services
        engine.isOnline = connectivity.isOnline
        engine.onChange = { [weak self] items in self?.persistQueue(items) }
        engine.onAuthFailure = { [weak self] id in self?.markNeedsReconnect(id) }
        engine.onBecameShareable = { [weak self] item in self?.itemBecameShareable(item) }
        engine.onFinished = { [weak self] item in self?.refreshLibrary(item.accountId, quiet: true) }
        connectivity.onChange = { [weak self] online in self?.engine.isOnline = online }
        recorder.onLimitReached = { [weak self] in self?.showToast("15-minute limit reached — recording stopped", symbol: "timer") }

        // Forward nested changes so views observing the model refresh.
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        avatars.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        if let demo {
            DemoData.install(demo, into: self)
        } else {
            UploadManager.shared.activate()
            showOnboarding = !settings.hasCompletedOnboarding || accounts.isEmpty
            registerShortcuts()
            cleanUploadedAudio()
            engine.pump()
            for a in accounts { refreshLibrary(a.id, quiet: true) }
            Task { nativeSignInAvailable = await NativeSignIn.isAvailable() }
        }
    }

    // MARK: Accounts

    var activeAccount: Account? { accounts.first { $0.id == activeAccountId } }
    func account(_ id: String?) -> Account? { accounts.first { $0.id == id } }

    func apiKey(for accountId: String) -> String? {
        if let k = keyCache[accountId] { return k }
        let k = Keychain.get(Keychain.apiKeyAccount(accountId))
        if let k { keyCache[accountId] = k }
        return k
    }

    /// Switching is instant: theme, destination and library change together; the library refreshes in the background.
    func switchAccount(to id: String) {
        guard id != activeAccountId, accounts.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            activeAccountId = id
            selectedEntryId = nil
            previewThemeId = nil
        }
        libraryPlayer.stop()
        refreshLibrary(id, quiet: true)
    }

    func signInWithGoogle(reconnecting existing: Account? = nil) async {
        signInInProgress = true
        signInError = nil
        defer { signInInProgress = false }
        do {
            let result = try await NativeSignIn().signIn()
            if let existing, let uid = existing.userId, uid != result.user.id {
                // Never attach a key for one Google account to another account's slot.
                try? await HMOClient(apiKey: result.api_key).revokeKey()
                signInError = "You signed in as \(result.user.email ?? "a different account"), but this slot belongs to \(existing.email ?? existing.title). Please choose the right Google account."
                return
            }
            addOrUpdate(user: result.user, key: result.api_key, method: .google)
        } catch NativeSignIn.Failure.cancelled {
            return
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// Fallback connection with an `hmo_` API key from Hear Me Out → Settings → API keys.
    func connect(apiKey raw: String, nickname: String?) async -> Bool {
        let key = raw.trimmed
        guard key.range(of: #"^hmo_[a-fA-F0-9]{48}$"#, options: .regularExpression) != nil else {
            signInError = "That doesn't look like a Hear Me Out API key. It starts with “hmo_” followed by 48 characters."
            return false
        }
        signInInProgress = true
        defer { signInInProgress = false }
        let client = HMOClient(apiKey: key)
        do {
            _ = try await client.listRecordings()
        } catch HMOError.unauthorised {
            signInError = "Hear Me Out didn't accept that key. It may have been revoked."
            return false
        } catch {
            signInError = error.localizedDescription
            return false
        }
        let user: RemoteUser
        if let me = try? await client.me() {
            user = me.user
        } else {
            // Without the /me endpoint there's no profile: identify the account by its key only.
            let hash = SHA256.hash(data: Data(key.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
            user = RemoteUser(id: "key-" + hash.prefix(16), email: nil, name: nil, avatar_url: nil)
        }
        addOrUpdate(user: user, key: key, method: .apiKey, nickname: nickname)
        return true
    }

    private func addOrUpdate(user: RemoteUser, key: String, method: AuthMethod, nickname: String? = nil) {
        let id = user.id
        do {
            try Keychain.set(key, account: Keychain.apiKeyAccount(id))
        } catch {
            signInError = "Couldn't save the key to your Keychain (\(error.localizedDescription))."
            return
        }
        keyCache[id] = key
        if let i = accounts.firstIndex(where: { $0.id == id }) {
            accounts[i].email = user.email ?? accounts[i].email
            accounts[i].displayName = user.name ?? accounts[i].displayName
            accounts[i].avatarURL = user.avatar_url ?? accounts[i].avatarURL
            accounts[i].needsReconnect = false
            accounts[i].authMethod = method
            accounts[i].keyPrefix = String(key.prefix(10))
            if let n = nickname?.trimmed, !n.isEmpty { accounts[i].nickname = n }
            avatars.refresh(accounts[i])
            showToast("\(accounts[i].title) reconnected")
        } else {
            let used = Set(accounts.map(\.themeId))
            let theme = ThemeCatalog.all.first { !used.contains($0.id) }?.id ?? ThemeCatalog.defaultId
            let a = Account(id: id, userId: id.hasPrefix("key-") ? nil : id, email: user.email, displayName: user.name, avatarURL: user.avatar_url,
                            nickname: nickname?.trimmed.nonEmpty, authMethod: method, keyPrefix: String(key.prefix(10)),
                            themeId: accounts.isEmpty ? settings.globalThemeId : theme, preferences: settings.defaultPreferences)
            accounts.append(a)
            showToast("Connected \(a.title)")
        }
        saveAccounts()
        engine.resumeAccount(id)
        if activeAccountId == nil || accounts.count == 1 { activeAccountId = id }
        refreshLibrary(id, quiet: false)
    }

    func markNeedsReconnect(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), !accounts[i].needsReconnect else { return }
        accounts[i].needsReconnect = true
        saveAccounts()
        showToast("\(accounts[i].title) needs reconnecting. Your recordings are safe.", symbol: "exclamationmark.triangle.fill", error: true)
    }

    func pendingUploadCount(for id: String) -> Int {
        engine.items(for: id).filter { !$0.cancelled && $0.upload != .ready }.count
    }

    /// Removes an account from this Mac. Keys this app created are revoked; pasted keys are only forgotten.
    func removeAccount(_ id: String) async {
        guard let a = account(id) else { return }
        if a.authMethod == .google, let key = apiKey(for: id) {
            try? await HMOClient(apiKey: key).revokeKey()
        }
        Keychain.delete(Keychain.apiKeyAccount(id))
        keyCache[id] = nil
        avatars.remove(id)
        accounts.removeAll { $0.id == id }
        library[id] = nil
        try? FileManager.default.removeItem(at: libraryFile(id))
        for item in engine.items(for: id) where item.isFinished || item.cancelled { engine.remove(item.id) }
        if activeAccountId == id { activeAccountId = accounts.first?.id }
        if settings.defaultAccountId == id { settings.defaultAccountId = nil }
        saveAccounts()
        showToast("Removed \(a.title) from this Mac")
    }

    func updateAccount(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
        saveAccounts()
    }

    // MARK: Theme

    var currentThemeId: String {
        if let p = previewThemeId { return p }
        if settings.useGlobalTheme { return settings.globalThemeId }
        return activeAccount?.themeId ?? settings.globalThemeId
    }

    func resolvedTheme(themeId: String? = nil) -> ResolvedTheme {
        let theme = ThemeCatalog.theme(themeId ?? currentThemeId)
        let scheme: ColorScheme
        switch settings.appearance {
        case .themeDefault: scheme = theme.preferred
        case .system: scheme = systemScheme
        case .light: scheme = .light
        case .dark: scheme = .dark
        }
        return ResolvedTheme(theme: theme, scheme: scheme)
    }

    func applyTheme(_ id: String, toAccount accountId: String? = nil) {
        withAnimation(.easeInOut(duration: 0.5)) {
            previewThemeId = nil
            if settings.useGlobalTheme || accounts.isEmpty {
                settings.globalThemeId = id
            } else if let target = accountId ?? activeAccountId {
                updateAccount(target) { $0.themeId = id }
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        switch recorder.state {
        case .recording, .paused: recorder.stop()
        case .starting: break
        default: startRecording()
        }
    }

    func startRecording() {
        guard let account = activeAccount else {
            tab = .settings
            settingsSection = .accounts
            showToast("Connect a Hear Me Out account first", symbol: "person.crop.circle.badge.plus", error: true)
            return
        }
        if case .finished = recorder.state {
            showToast("Save or discard the last recording first", symbol: "tray.full.fill", error: true)
            tab = .create
            return
        }
        guard let device = devices.captureDevice(for: devices.current) else {
            showToast("No microphone is connected", symbol: "mic.slash.fill", error: true)
            return
        }
        tab = .create
        Task { await recorder.start(device: device, accountId: account.id, quality: settings.recordingQuality) }
    }

    /// Queues a take for upload to the account it was recorded for (or one the user explicitly chose).
    func save(take: Take, title: String, to accountId: String) {
        guard let account = account(accountId) else { return }
        let size = Int64((try? take.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = QueueItem(accountId: account.id, recordedAt: take.recordedAt, durationSeconds: take.duration, sizeBytes: size,
                             fileExtension: "m4a", originalFilename: "voice-note-\(Self.fileStamp(take.recordedAt)).m4a",
                             audioFileName: take.url.lastPathComponent, source: .recording, userTitle: title, preferences: account.preferences)
        engine.add(item)
        recorder.reset(deleteFile: false)
        showToast("Uploading to \(account.title)…", symbol: "arrow.up.circle.fill")
    }

    func discardTake() {
        recorder.reset(deleteFile: true)
    }

    static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: d)
    }

    // MARK: Import

    @Published var importCandidates: [ImportCandidate] = []
    @Published var showImportSheet = false

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioImporter.readableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio files to upload to Hear Me Out (up to 15 minutes each)."
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            var list: [ImportCandidate] = []
            for u in urls.prefix(20) { list.append(await AudioImporter.inspect(u)) }
            importCandidates = list
            showImportSheet = true
            tab = .create
        }
    }

    func commitImports(_ list: [ImportCandidate], accountId: String, preferences: ProcessingPreferences) async {
        guard let account = account(accountId) else { return }
        var added = 0
        for c in list where c.canUpload {
            do {
                let prepared = try await AudioImporter.prepare(c)
                let item = QueueItem(accountId: account.id, recordedAt: c.recordedAt, recordedAtIsEstimated: c.dateSource != .metadata && c.dateSource != .manual,
                                     durationSeconds: c.duration, sizeBytes: prepared.size, fileExtension: prepared.ext,
                                     originalFilename: c.originalName, audioFileName: prepared.url.lastPathComponent, source: .upload,
                                     userTitle: c.title == (c.originalName as NSString).deletingPathExtension && preferences.titleProvider != .manual ? nil : c.title,
                                     preferences: preferences)
                engine.add(item)
                added += 1
            } catch {
                showToast("Couldn't import \(c.originalName): \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", error: true)
            }
        }
        importCandidates = []
        showImportSheet = false
        if added > 0 { showToast("Uploading \(added) file\(added == 1 ? "" : "s") to \(account.title)…", symbol: "arrow.up.circle.fill") }
    }

    // MARK: Library

    func libraryFile(_ id: String) -> URL {
        let safe = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        return AppPaths.libraryCache.appendingPathComponent("\(safe).json")
    }

    func entries(for accountId: String?) -> [LibraryEntry] {
        guard let accountId else { return [] }
        return LibraryQuery.merge(remote: library[accountId] ?? [], local: engine.items(for: accountId))
    }

    func refreshLibrary(_ id: String, quiet: Bool) {
        guard !isDemo, !libraryLoading.contains(id), let key = apiKey(for: id), account(id)?.needsReconnect == false else { return }
        libraryLoading.insert(id)
        Task {
            defer { libraryLoading.remove(id) }
            do {
                let items = try await HMOClient(apiKey: key).listRecordings()
                library[id] = items
                libraryError[id] = nil
                try? JSONStore<[RemoteRecording]>(url: libraryFile(id)).save(items)
            } catch HMOError.unauthorised {
                markNeedsReconnect(id)
            } catch {
                libraryError[id] = error.localizedDescription
                if !quiet { showToast("Couldn't refresh the library", symbol: "wifi.exclamationmark", error: true) }
            }
        }
    }

    func loadDetail(_ entry: LibraryEntry, accountId: String) {
        guard !isDemo, let rid = entry.remote?.id ?? entry.local?.recordingId, let key = apiKey(for: accountId) else { return }
        Task {
            if let r = try? await HMOClient(apiKey: key).recording(id: rid) { details[rid] = r }
        }
    }

    /// Local audio if still cached; otherwise a signed URL from the playback endpoint (Mac backend addition).
    func playbackURL(for entry: LibraryEntry, accountId: String) async -> URL? {
        if let l = entry.local, !l.audioRemoved {
            let u = AppPaths.audio.appendingPathComponent(l.audioFileName)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        guard !isDemo, let rid = entry.remote?.id, let key = apiKey(for: accountId) else { return nil }
        do {
            let u = try await HMOClient(apiKey: key).playbackURL(recordingId: rid)
            playbackAvailable = true
            return u
        } catch HMOError.notFound {
            playbackAvailable = false
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Sharing

    func copy(_ format: ShareFormat, links: ShareLinks) {
        Clipboard.copy(format, links: links)
        if settings.preferredShareFormat != format { settings.preferredShareFormat = format }
        showToast(format.confirmation, symbol: format.symbol)
    }

    var latestShareable: (title: String, links: ShareLinks)? {
        let local = engine.items.filter { $0.share != nil && !$0.cancelled }.max { $0.createdAt < $1.createdAt }
        if let l = local, let s = l.share { return (l.displayTitle, s) }
        if let id = activeAccountId, let r = library[id]?.first(where: { $0.isShareable }), let s = r.shareUrl, let e = r.embedUrl, let c = r.embedCode {
            return (r.title, ShareLinks(shareUrl: s, embedUrl: e, embedCode: c))
        }
        return nil
    }

    func copyLatestLink() {
        guard let latest = latestShareable else {
            showToast("Nothing to share yet", symbol: "link", error: true)
            return
        }
        copy(.link, links: latest.links)
    }

    private func itemBecameShareable(_ item: QueueItem) {
        if settings.copyLinkWhenReady, let s = item.share {
            Clipboard.copy(.link, links: s)
            showToast("Ready — link copied", symbol: "link")
        } else {
            showToast("Ready to share", symbol: "checkmark.seal.fill")
        }
        refreshLibrary(item.accountId, quiet: true)
    }

    // MARK: Storage

    var localAudioBytes: Int64 { ModelDiscovery.directorySize(AppPaths.audio) }

    /// Removes cached audio for recordings that are safely on the server. Unuploaded audio is never removed.
    func removeUploadedAudio(olderThan days: Int? = nil) -> Int {
        var removed = 0
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        for item in engine.items where item.upload == .ready && item.isFinished && !item.audioRemoved {
            if let cutoff, item.createdAt > cutoff { continue }
            try? FileManager.default.removeItem(at: AppPaths.audio.appendingPathComponent(item.audioFileName))
            engine.update(item.id) { $0.audioRemoved = true }
            removed += 1
        }
        return removed
    }

    private func cleanUploadedAudio() {
        guard settings.removeUploadedAudioAfterDays > 0 else { return }
        _ = removeUploadedAudio(olderThan: settings.removeUploadedAudioAfterDays)
        // Finished items older than 60 days leave the Activity list (the library still shows them).
        let old = Date().addingTimeInterval(-60 * 86_400)
        for item in engine.items where (item.isFinished || item.cancelled) && item.audioRemoved && item.createdAt < old { engine.remove(item.id) }
    }

    // MARK: Persistence

    private func persistQueue(_ items: [QueueItem]) {
        guard !isDemo else { return }
        do { try JSONStore<[QueueItem]>(url: AppPaths.queueFile).save(items) }
        catch { appLog.error("Queue save failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func saveAccounts() {
        guard !isDemo else { return }
        try? JSONStore<[Account]>(url: AppPaths.accountsFile).save(accounts)
    }

    private func saveSettings() {
        guard !isDemo else { return }
        try? JSONStore<AppSettings>(url: AppPaths.settingsFile).save(settings)
    }

    private func settingsChanged(_ old: AppSettings) {
        if old.recordShortcut != settings.recordShortcut || old.openShortcut != settings.openShortcut || old.copyShortcut != settings.copyShortcut {
            registerShortcuts()
        }
    }

    // MARK: Shortcuts

    @Published private(set) var shortcutConflicts: Set<HotKeyAction> = []

    func registerShortcuts() {
        guard !isDemo else { return }
        HotKeyCentre.shared.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleRecording: self.toggleRecording()
            case .openApp: self.bringToFront()
            case .copyLatestLink: self.copyLatestLink()
            }
        }
        var conflicts: Set<HotKeyAction> = []
        if !HotKeyCentre.shared.register(.toggleRecording, settings.recordShortcut) { conflicts.insert(.toggleRecording) }
        if !HotKeyCentre.shared.register(.openApp, settings.openShortcut) { conflicts.insert(.openApp) }
        if !HotKeyCentre.shared.register(.copyLatestLink, settings.copyShortcut) { conflicts.insert(.copyLatestLink) }
        shortcutConflicts = conflicts
    }

    var openMainWindow: (() -> Void)?

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: Feedback

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill", error: Bool = false) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = Toast(message: message, symbol: symbol, isError: error) }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: error ? 4_500_000_000 : 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        withAnimation(.easeInOut(duration: 0.4)) { showOnboarding = false }
        tab = .create
    }
}

// MARK: - Demo mode (screenshots and UI tests only; never touches real data)

enum DemoScenario: String {
    case create, recording, review, library, activity, settings, themes, onboarding, accounts, menubar
}

extension AppModel {
    /// Test hooks used only by DemoData.
    func demoSet(accounts: [Account], library: [String: [RemoteRecording]]) {
        self.accounts = accounts
        self.library = library
        self.activeAccountId = accounts.first?.id
    }
}
