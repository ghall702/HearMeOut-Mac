import Foundation

/// Validates and tidies AI-generated titles (Apple Intelligence or OpenAI) before they are used.
public enum TitleSanitiser {
    public static let maxLength = 80

    /// Words that on their own make a useless title.
    static let generic: Set<String> = [
        "voice note", "voice memo", "voice message", "untitled", "untitled recording", "recording", "audio",
        "transcript", "title", "memo", "note", "message", "no speech detected", "summary", "n/a", "none",
    ]

    /// Returns a clean title, or nil when the text isn't usable as a title.
    public static func clean(_ raw: String) -> String? {
        // First non-empty line only.
        guard var s = raw.components(separatedBy: .newlines).map({ $0.trimmed }).first(where: { !$0.isEmpty }) else { return nil }
        // Strip "Title:" style prefixes and markdown decoration.
        for prefix in ["title:", "suggested title:", "here's a title:", "here is a title:"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmed
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`>-• ").union(.whitespaces))
        let quotes = CharacterSet(charactersIn: "\"'“”‘’«»")
        s = s.trimmingCharacters(in: quotes).trimmed
        while let last = s.last, ".!;:,".contains(last) { s.removeLast() }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        guard !s.isEmpty else { return nil }
        if generic.contains(s.lowercased()) { return nil }
        // A "title" that's really a paragraph.
        if s.split(separator: " ").count > 14 { return nil }
        if s.count > maxLength {
            let cut = s.prefix(maxLength)
            if let space = cut.lastIndex(of: " ") { s = String(cut[..<space]) } else { s = String(cut) }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–— "))
        }
        return s
    }

    /// The instruction given to every title model, so providers behave consistently.
    public static let instructions = """
    You write titles for voice notes. Reply with the title only: no quotation marks, no full stop, no \
    explanation. Use British English spelling. Keep it between 3 and 9 words. Name the actual subject \
    and, where it's obvious, who it's for (for example "Feedback on Sam's Year 11 essay"). Never write \
    a summary or a generic title such as "Voice note".
    """

    /// Keeps the prompt small: the start and end of long transcripts carry most of the topic.
    public static func excerpt(_ transcript: String, limit: Int = 6000) -> String {
        let t = transcript.trimmed
        guard t.count > limit else { return t }
        let head = t.prefix(limit * 2 / 3)
        let tail = t.suffix(limit / 3)
        return "\(head)\n…\n\(tail)"
    }
}
