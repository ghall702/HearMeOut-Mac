import Foundation

/// Limits and formats from the Hear Me Out technical handbook (§2 invariants, §6.1).
public enum HMOLimits {
    /// 15-minute cap (`MAX_RECORDING_SECONDS`).
    public static let maxRecordingSeconds: Double = 900
    /// The server accepts up to 2 s over the cap.
    public static let durationToleranceSeconds: Double = 2
    /// 500 MB per file (`MAX_UPLOAD_BYTES`).
    public static let maxUploadBytes: Int64 = 500 * 1024 * 1024
    /// `title` on finalise is limited to 200 characters.
    public static let maxTitleLength = 200
    /// `transcript` on finalise is limited to 200 000 characters.
    public static let maxTranscriptLength = 200_000
    /// GET /recordings returns at most this many items.
    public static let libraryPageLimit = 200
    /// The transcript the server stores when nothing was said. It never produces a title.
    public static let noSpeechTranscript = "[No speech detected]"
    /// The server's default title.
    public static let serverDefaultTitle = "Untitled recording"

    public static func durationIsAcceptable(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= maxRecordingSeconds + durationToleranceSeconds
    }
}

/// Audio container formats the backend accepts (`ext` in POST /uploads).
public enum AudioFormat {
    public static let backendExtensions: [String] = ["mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "weba", "webm", "mp4"]

    /// Formats macOS can read that the backend does not accept; these are converted before upload.
    public static let convertibleExtensions: [String] = ["aif", "aiff", "aifc", "caf", "m4b", "mov", "3gp", "amr"]

    public static func isBackendSupported(_ ext: String) -> Bool {
        backendExtensions.contains(ext.lowercased())
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "flac": return "audio/flac"
        case "weba", "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }

    /// Whether AVFoundation (and therefore WhisperKit) can normally decode this format on macOS.
    public static func isLocallyDecodable(_ ext: String) -> Bool {
        !["ogg", "oga", "opus", "weba", "webm"].contains(ext.lowercased())
    }
}

/// `recordedAt` must be ISO 8601 with a timezone, not in the future (> 5 min) and not before 2000.
public enum RecordedAt {
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    public static let earliest: Date = {
        var c = DateComponents()
        c.year = 2000; c.month = 1; c.day = 1
        c.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// Clamps a date into the range the server accepts, or returns nil when it is unusable.
    public static func validated(_ date: Date, now: Date = Date()) -> Date? {
        if date < earliest { return nil }
        if date > now.addingTimeInterval(5 * 60) { return nil }
        return date
    }
}

/// Flexible ISO 8601 parsing for timestamps returned by the API (with or without fractional seconds).
public enum ISODate {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        if let d = b.date(from: s) { return d }
        // Postgres style "2026-11-20 09:30:00.123+00"
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ss.SSSXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ssX"] {
            p.dateFormat = fmt
            if let d = p.date(from: s) { return d }
        }
        return nil
    }
}

/// A human, British-English title used when no generated or typed title exists, so the server
/// never treats the recording as "Untitled" (which would start cloud titling the user didn't choose).
public enum ProvisionalTitle {
    public static func make(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy, HH:mm"
        return "Voice note · \(f.string(from: date))"
    }

    public static func isProvisional(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.hasPrefix("Voice note · ")
    }
}
