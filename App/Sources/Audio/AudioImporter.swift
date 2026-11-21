import AVFoundation
import UniformTypeIdentifiers
import HearMeOutCore

/// An audio file being prepared for upload.
struct ImportCandidate: Identifiable, Equatable {
    enum DateSource: Equatable {
        /// Embedded recording metadata (QuickTime/ID3 creation date) — trusted.
        case metadata
        /// The file's creation date on disk — plausible but not proof; shown for confirmation.
        case fileDate
        /// Chosen by the user.
        case manual
        /// Nothing available.
        case unknown
    }

    let id = UUID()
    let sourceURL: URL
    var originalName: String
    var ext: String
    var duration: Double
    var sizeBytes: Int64
    var recordedAt: Date
    var dateSource: DateSource
    var title: String
    /// Set when the format must be converted before upload.
    var conversion: String?
    var problem: String?

    var canUpload: Bool { problem == nil }

    var dateSourceText: String {
        switch dateSource {
        case .metadata: return "From the file's recording metadata"
        case .fileDate: return "From the file's creation date — please check"
        case .manual: return "Set by you"
        case .unknown: return "No recording date found — please set one"
        }
    }
}

enum AudioImporter {
    static var readableTypes: [UTType] {
        var t: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        for ext in ["flac", "ogg", "oga", "opus", "webm", "weba", "aac", "m4a", "caf"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }

    /// Reads duration, size and the most trustworthy recording date. Never modifies the file.
    static func inspect(_ url: URL) async -> ImportCandidate {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        var c = ImportCandidate(sourceURL: url, originalName: name, ext: ext, duration: 0, sizeBytes: size, recordedAt: Date(),
                                dateSource: .unknown, title: (name as NSString).deletingPathExtension, conversion: nil, problem: nil)

        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(d)
            if s.isFinite && s > 0 { c.duration = s }
        }
        if let meta = await embeddedCreationDate(asset), let valid = RecordedAt.validated(meta) {
            c.recordedAt = valid
            c.dateSource = .metadata
        } else if let created = values?.creationDate, let valid = RecordedAt.validated(created) {
            c.recordedAt = valid
            c.dateSource = .fileDate
        }

        if !AudioFormat.isBackendSupported(ext) {
            if AudioFormat.convertibleExtensions.contains(ext) {
                c.conversion = "Hear Me Out doesn't accept .\(ext) files, so this will be converted without quality loss where possible."
            } else {
                c.problem = "Hear Me Out can't accept .\(ext) files."
            }
        }
        if c.duration == 0 && c.problem == nil && AudioFormat.isLocallyDecodable(ext) {
            c.problem = "This file couldn't be read. It may be damaged or not an audio file."
        }
        if c.duration > HMOLimits.maxRecordingSeconds + HMOLimits.durationToleranceSeconds {
            c.problem = "This recording is \(c.duration.clockText) long. Hear Me Out accepts up to 15 minutes."
        }
        if size > HMOLimits.maxUploadBytes {
            c.problem = "This file is \(size.fileSizeText). Hear Me Out accepts up to 500 MB."
        }
        if size == 0 { c.problem = "This file is empty." }
        return c
    }

    static func embeddedCreationDate(_ asset: AVURLAsset) async -> Date? {
        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) { items += common }
        if let all = try? await asset.load(.metadata) { items += all }
        for item in items {
            let key = item.commonKey?.rawValue ?? (item.key as? String) ?? ""
            let id = item.identifier?.rawValue ?? ""
            let isDate = key == AVMetadataKey.commonKeyCreationDate.rawValue || id.contains("creationdate") || id.contains("TDRC") || id.contains("TDOR") || key == "date"
            guard isDate else { continue }
            if let d = try? await item.load(.dateValue) { return d }
            if let s = try? await item.load(.stringValue), let d = ISODate.parse(s) ?? parseLooseDate(s) { return d }
        }
        return nil
    }

    static func parseLooseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Copies (or converts) the file into the app's audio folder, so the original is never touched
    /// and the upload can be retried even if the original moves.
    static func prepare(_ c: ImportCandidate) async throws -> (url: URL, ext: String, size: Int64) {
        let id = UUID().uuidString
        let fm = FileManager.default
        let scoped = c.sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { c.sourceURL.stopAccessingSecurityScopedResource() } }

        if AudioFormat.isBackendSupported(c.ext) {
            let dest = AppPaths.audio.appendingPathComponent("\(id).\(c.ext)")
            try fm.copyItem(at: c.sourceURL, to: dest)
            AppPaths.protect(dest)
            return (dest, c.ext, Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        // Lossless PCM sources (AIFF/CAF) become WAV — the same samples in a container the backend accepts.
        let wav = AppPaths.audio.appendingPathComponent("\(id).wav")
        do {
            try convertToWAV(from: c.sourceURL, to: wav)
            let size = Int64((try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > 0 && size <= HMOLimits.maxUploadBytes {
                AppPaths.protect(wav)
                return (wav, "wav", size)
            }
            try? fm.removeItem(at: wav)
        } catch {
            try? fm.removeItem(at: wav)
        }
        // Otherwise high-bit-rate AAC.
        let m4a = AppPaths.audio.appendingPathComponent("\(id).m4a")
        try await exportM4A(from: c.sourceURL, to: m4a)
        AppPaths.protect(m4a)
        return (m4a, "m4a", Int64((try? m4a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    static func convertToWAV(from src: URL, to dest: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        var settings = input.fileFormat.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMBitDepthKey] = min(24, (input.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 16)
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { throw TranscriptionError("Couldn't allocate audio buffer.") }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    static func exportM4A(from src: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError("This file can't be converted on this Mac.")
        }
        session.outputURL = dest
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed {
            throw TranscriptionError(session.error?.localizedDescription ?? "Conversion failed.")
        }
    }
}
