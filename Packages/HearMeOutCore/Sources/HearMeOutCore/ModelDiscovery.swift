import Foundation

/// The on-disk format of a speech model folder.
public enum ModelFormat: String, Codable, Sendable {
    /// WhisperKit Core ML bundle (AudioEncoder/TextDecoder/MelSpectrogram .mlmodelc). Loadable by Hear Me Out.
    case whisperKitCoreML
    /// whisper.cpp GGML/GGUF weights. A different engine: not loadable by WhisperKit.
    case ggml
    /// PyTorch / safetensors / MLX weights. Not loadable by WhisperKit.
    case otherWeights
    case unknown

    public var isCompatible: Bool { self == .whisperKitCoreML }

    public var explanation: String {
        switch self {
        case .whisperKitCoreML: return "WhisperKit Core ML model — Hear Me Out can use it directly."
        case .ggml: return "whisper.cpp (GGML) model — a different engine. Hear Me Out uses WhisperKit, which can't load these files."
        case .otherWeights: return "Raw model weights (PyTorch, safetensors or MLX). WhisperKit needs the compiled Core ML version."
        case .unknown: return "This folder doesn't contain a recognisable Whisper model."
        }
    }
}

public enum ModelOrigin: String, Codable, Sendable {
    /// Found in Let's Meet Note Taker's data folder; used in place, never copied or modified.
    case sharedFromLetsMeet
    /// Downloaded by Hear Me Out into its own folder.
    case hearMeOut
    /// A folder the user chose.
    case userFolder
    /// WhisperKit's default Hugging Face download location.
    case huggingFaceCache
}

public struct DiscoveredModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String { folder.path }
    public var name: String
    public var folder: URL
    /// Base folder that contains `models/openai/whisper-*/tokenizer.json` (WhisperKit's tokenizer folder).
    public var tokenizerBase: URL?
    public var format: ModelFormat
    public var origin: ModelOrigin
    public var sizeBytes: Int64

    public init(name: String, folder: URL, tokenizerBase: URL?, format: ModelFormat, origin: ModelOrigin, sizeBytes: Int64) {
        self.name = name
        self.folder = folder
        self.tokenizerBase = tokenizerBase
        self.format = format
        self.origin = origin
        self.sizeBytes = sizeBytes
    }

    /// A friendly name such as "Large v3 Turbo (632 MB)".
    public var friendlyName: String { ModelNames.friendly(name) }
}

public enum ModelNames {
    public static func friendly(_ variant: String) -> String {
        var s = variant
        for p in ["openai_whisper-", "distil-whisper_distil-", "whisper-"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        var size: String?
        if let r = s.range(of: #"_(\d+)MB$"#, options: .regularExpression) {
            size = String(s[r]).dropFirst().replacingOccurrences(of: "MB", with: " MB")
            s.removeSubrange(r)
        }
        s = s.replacingOccurrences(of: "-v20240930", with: "")
        let words = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { w -> String in
            let l = w.lowercased()
            if l == "en" { return "(English)" }
            if l.first == "v", l.dropFirst().allSatisfy({ $0.isNumber }) { return l }
            return l.prefix(1).uppercased() + l.dropFirst()
        }
        let base = words.joined(separator: " ")
        return size.map { "\(base) · \($0)" } ?? base
    }
}

/// Finds Whisper models on disk without modifying anything.
public enum ModelDiscovery {
    public static let whisperKitRepoPath = "models/argmaxinc/whisperkit-coreml"
    static let requiredBundles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]

    /// The real home folder (outside the app sandbox container).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Let's Meet Note Taker (bundle `com.georgehalltuition.lessonnotes`) is sandboxed and stores
    /// WhisperKit models in `Application Support/LessonNotes/WhisperModels` inside its container,
    /// using WhisperKit's layout `models/argmaxinc/whisperkit-coreml/<variant>`.
    public static func letsMeetModelBases(home: URL = realHome) -> [URL] {
        [
            home.appendingPathComponent("Library/Containers/com.georgehalltuition.lessonnotes/Data/Library/Application Support/LessonNotes/WhisperModels", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/LessonNotes/WhisperModels", isDirectory: true),
        ]
    }

    /// WhisperKit's default download location when no `downloadBase` is given.
    public static func huggingFaceBases(home: URL = realHome) -> [URL] {
        [home.appendingPathComponent("Documents/huggingface", isDirectory: true)]
    }

    public static func format(of folder: URL) -> ModelFormat {
        let fm = FileManager.default
        if requiredBundles.allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return .whisperKitCoreML }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.contains(where: { $0.hasPrefix("ggml") || $0.hasSuffix(".gguf") || ($0.hasSuffix(".bin") && $0.contains("ggml")) }) { return .ggml }
        if names.contains(where: { $0.hasSuffix(".safetensors") || $0.hasSuffix(".pt") || $0.hasSuffix(".npz") || $0 == "pytorch_model.bin" }) { return .otherWeights }
        return .unknown
    }

    /// For `<base>/models/argmaxinc/whisperkit-coreml/<variant>`, the tokenizer base is `<base>`.
    public static func tokenizerBase(forModelFolder folder: URL) -> URL? {
        let comps = folder.standardizedFileURL.pathComponents
        guard comps.count >= 5 else { return nil }
        let tail = Array(comps.suffix(4).prefix(3))
        guard tail == ["models", "argmaxinc", "whisperkit-coreml"] else { return nil }
        var base = folder.standardizedFileURL
        for _ in 0..<4 { base.deleteLastPathComponent() }
        return base
    }

    /// Whether a tokenizer for this variant is already present (so loading needs no network).
    public static func hasTokenizer(base: URL, variant: String) -> Bool {
        let openai = base.appendingPathComponent("models/openai", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: openai.path) else { return false }
        let wanted = tokenizerRepo(for: variant)
        return names.contains { n in
            (wanted == nil || n == wanted) && FileManager.default.fileExists(atPath: openai.appendingPathComponent(n).appendingPathComponent("tokenizer.json").path)
        }
    }

    /// Best guess of the tokenizer repo WhisperKit uses for a variant (e.g. "whisper-large-v3").
    public static func tokenizerRepo(for variant: String) -> String? {
        let v = variant.lowercased()
        for size in ["large-v3", "large-v2", "large", "medium.en", "medium", "small.en", "small", "base.en", "base", "tiny.en", "tiny"] where v.contains(size) {
            return "whisper-\(size)"
        }
        return nil
    }

    /// Scans a base folder (or a model folder itself) for models.
    public static func scan(_ url: URL, origin: ModelOrigin, measureSize: Bool = true) -> [DiscoveredModel] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let direct = format(of: url)
        if direct != .unknown {
            return [model(at: url, format: direct, origin: origin, measureSize: measureSize)]
        }
        var candidates: [URL] = []
        let repo = url.appendingPathComponent(whisperKitRepoPath, isDirectory: true)
        for parent in [repo, url] {
            if let items = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                candidates += items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
        }
        var seen = Set<String>()
        var out: [DiscoveredModel] = []
        for c in candidates where seen.insert(c.standardizedFileURL.path).inserted {
            let f = format(of: c)
            if f != .unknown { out.append(model(at: c, format: f, origin: origin, measureSize: measureSize)) }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func model(at folder: URL, format: ModelFormat, origin: ModelOrigin, measureSize: Bool) -> DiscoveredModel {
        DiscoveredModel(name: folder.lastPathComponent, folder: folder, tokenizerBase: tokenizerBase(forModelFolder: folder) ?? folder.deletingLastPathComponent(),
                        format: format, origin: origin, sizeBytes: measureSize ? directorySize(folder) : 0)
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
