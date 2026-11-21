import AppKit
import WhisperKit
import HearMeOutCore

/// Finds, shares and downloads WhisperKit models.
///
/// Let's Meet Note Taker uses the same engine (WhisperKit 1.1.1, Core ML models in WhisperKit's
/// `models/argmaxinc/whisperkit-coreml/<variant>` layout), so its downloaded models can be used
/// in place. Because both apps are sandboxed, Hear Me Out asks you to select Let's Meet's model
/// folder once; it keeps a read-only security-scoped bookmark and never copies, changes or deletes
/// those files.
@MainActor
final class ModelLibrary: ObservableObject {
    struct Selection: Codable, Equatable {
        var variant: String
        var folderPath: String
        var origin: ModelOrigin
    }

    @Published private(set) var models: [DiscoveredModel] = []
    @Published private(set) var downloadable: [String] = []
    @Published private(set) var recommended: String?
    @Published private(set) var downloading: [String: Double] = [:]
    @Published private(set) var preparing: Set<String> = []
    @Published var selection: Selection? { didSet { persistSelection() } }
    @Published private(set) var lastError: String?
    @Published private(set) var sharedFolderGranted = false
    @Published private(set) var isScanning = false

    private let bookmarkKey = "sharedModelBookmarks"
    private let selectionKey = "whisperSelection"
    private var scopedURLs: [URL] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: selectionKey), let s = try? JSONDecoder().decode(Selection.self, from: data) {
            selection = s
        }
        let local = WhisperKit.recommendedModels()
        recommended = local.default
        downloadable = local.supported
        resolveBookmarks()
        rescan()
    }

    // MARK: State

    var selectedModel: DiscoveredModel? {
        guard let s = selection else { return nil }
        return models.first { $0.folder.path == s.folderPath } ?? models.first { $0.name == s.variant && $0.format.isCompatible }
    }

    enum Status: Equatable {
        case ready(DiscoveredModel)
        case missingShared
        case none
    }

    var status: Status {
        if let m = selectedModel { return .ready(m) }
        if selection?.origin == .sharedFromLetsMeet { return .missingShared }
        return .none
    }

    var hearMeOutStorage: Int64 { ModelDiscovery.directorySize(AppPaths.models) }

    // MARK: Discovery

    /// Rescans Hear Me Out's own folder, every granted shared folder and default locations (if readable).
    func rescan() {
        isScanning = true
        let shared = scopedURLs
        Task.detached(priority: .utility) {
            var found: [DiscoveredModel] = []
            found += ModelDiscovery.scan(AppPaths.models, origin: .hearMeOut)
            for url in shared {
                let isLetsMeet = url.path.contains("LessonNotes")
                found += ModelDiscovery.scan(url, origin: isLetsMeet ? .sharedFromLetsMeet : .userFolder)
            }
            // Readable only when the user has granted access (or the app runs unsandboxed).
            for base in ModelDiscovery.letsMeetModelBases() where !shared.contains(where: { $0.path == base.path }) {
                found += ModelDiscovery.scan(base, origin: .sharedFromLetsMeet)
            }
            for base in ModelDiscovery.huggingFaceBases() {
                found += ModelDiscovery.scan(base, origin: .huggingFaceCache)
            }
            var seen = Set<String>()
            let unique = found.filter { seen.insert($0.folder.standardizedFileURL.path).inserted }
            await MainActor.run {
                self.models = unique
                self.isScanning = false
                if self.selection == nil, let first = unique.first(where: { $0.format.isCompatible }) {
                    self.select(first)
                }
            }
        }
    }

    func select(_ model: DiscoveredModel) {
        guard model.format.isCompatible else { return }
        selection = Selection(variant: model.name, folderPath: model.folder.path, origin: model.origin)
    }

    /// Asks the user to select Let's Meet's model folder (pre-navigated) and keeps read-only access.
    func requestLetsMeetAccess() {
        let panel = NSOpenPanel()
        panel.message = "Select Let's Meet's “WhisperModels” folder. Hear Me Out will only read the model — nothing is copied, changed or deleted."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        let candidates = ModelDiscovery.letsMeetModelBases()
        panel.directoryURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSharedFolder(url)
    }

    /// Any folder containing WhisperKit models (manual selection).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder containing WhisperKit Core ML models."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSharedFolder(url)
    }

    private func addSharedFolder(_ url: URL) {
        let found = ModelDiscovery.scan(url, origin: .userFolder, measureSize: false)
        if found.isEmpty {
            lastError = "No Whisper models were found in “\(url.lastPathComponent)”."
            return
        }
        if !found.contains(where: { $0.format.isCompatible }) {
            lastError = found.first!.format.explanation
        } else {
            lastError = nil
        }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            var all = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] ?? []
            all.append(data)
            UserDefaults.standard.set(all, forKey: bookmarkKey)
        } catch {
            appLog.error("Bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        sharedFolderGranted = true
        if let m = ModelDiscovery.scan(url, origin: url.path.contains("LessonNotes") ? .sharedFromLetsMeet : .userFolder).first(where: { $0.format.isCompatible }) {
            select(m)
        }
        rescan()
    }

    private func resolveBookmarks() {
        let all = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] ?? []
        var keep: [Data] = []
        for data in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
                keep.append(stale ? ((try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data) : data)
            }
        }
        UserDefaults.standard.set(keep, forKey: bookmarkKey)
        sharedFolderGranted = !scopedURLs.isEmpty
    }

    func forgetSharedFolders() {
        for u in scopedURLs { u.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        sharedFolderGranted = false
        if selection?.origin == .sharedFromLetsMeet || selection?.origin == .userFolder { selection = nil }
        rescan()
    }

    private func persistSelection() {
        if let s = selection, let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: selectionKey) }
        else { UserDefaults.standard.removeObject(forKey: selectionKey) }
    }

    // MARK: Downloads (only on request; sizes shown first)

    func refreshDownloadable() async {
        let remote = await WhisperKit.recommendedRemoteModels(downloadBase: AppPaths.models)
        recommended = remote.default
        var names = remote.supported
        if let all = try? await WhisperKit.fetchAvailableModels(downloadBase: AppPaths.models), !all.isEmpty {
            names = all.filter { remote.supported.isEmpty || remote.supported.contains($0) }
            if names.isEmpty { names = all }
        }
        if !names.isEmpty { downloadable = names }
    }

    func download(_ variant: String) async {
        guard downloading[variant] == nil else { return }
        lastError = nil
        downloading[variant] = 0
        defer { downloading[variant] = nil }
        do {
            let folder = try await WhisperKit.download(variant: variant, downloadBase: AppPaths.models) { p in
                let f = p.fractionCompleted
                Task { @MainActor in self.downloading[variant] = f }
            }
            downloading[variant] = nil
            preparing.insert(variant)
            defer { preparing.remove(variant) }
            // Load once so the tokenizer is fetched and Core ML compiles the model.
            let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: AppPaths.models, verbose: false, logLevel: .none,
                                          prewarm: true, load: true, download: false)
            let kit = try await WhisperKit(config)
            await kit.unloadModels()
            rescan()
            selection = Selection(variant: variant, folderPath: folder.path, origin: .hearMeOut)
        } catch {
            lastError = "Download of \(ModelNames.friendly(variant)) failed: \(error.localizedDescription)"
            rescan()
        }
    }

    /// Deletes a model Hear Me Out downloaded. Shared models are never deleted.
    func delete(_ model: DiscoveredModel) {
        guard model.origin == .hearMeOut, model.folder.path.hasPrefix(AppPaths.models.path) else { return }
        try? FileManager.default.removeItem(at: model.folder)
        if selection?.folderPath == model.folder.path { selection = nil }
        rescan()
    }

    /// What the transcriber should load: model folder and the tokenizer folder to use.
    func resolvedForTranscription() -> (name: String, folder: URL, tokenizerBase: URL)? {
        guard let m = selectedModel else { return nil }
        // Use the shared tokenizer if it's already there (read-only is fine); otherwise use our own folder,
        // where WhisperKit can fetch the small tokenizer file without touching the other app's data.
        if let base = m.tokenizerBase, ModelDiscovery.hasTokenizer(base: base, variant: m.name) {
            return (m.name, m.folder, base)
        }
        return (m.name, m.folder, AppPaths.models)
    }
}
