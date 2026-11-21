import Foundation

public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, shared, transcribed, processing, unplayed
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All"
        case .shared: return "Listened to"
        case .transcribed: return "Transcribed"
        case .processing: return "In progress"
        case .unplayed: return "Not yet played"
        }
    }
}

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, mostPlayed, longest, title
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .mostPlayed: return "Most played"
        case .longest: return "Longest"
        case .title: return "Title A–Z"
        }
    }
}

/// One row in the library: a server recording, a local queue item, or both merged.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var remote: RemoteRecording?
    public var local: QueueItem?

    public init(remote: RemoteRecording?, local: QueueItem?) {
        self.remote = remote
        self.local = local
        self.id = remote?.id ?? local?.recordingId ?? local!.id.uuidString
    }

    public var title: String {
        if let l = local, l.userTitle != nil || l.generatedTitle != nil { return l.displayTitle }
        if let r = remote { return r.title }
        return local?.displayTitle ?? "Voice note"
    }
    public var date: Date { remote?.recordedDate ?? local?.recordedAt ?? .distantPast }
    public var duration: Double { remote?.duration_seconds ?? local?.durationSeconds ?? 0 }
    public var plays: Int { remote?.plays ?? 0 }
    public var shareUrl: String? { remote?.shareUrl ?? local?.share?.shareUrl }
    public var links: ShareLinks? {
        if let r = remote, let s = r.shareUrl, let e = r.embedUrl, let c = r.embedCode { return ShareLinks(shareUrl: s, embedUrl: e, embedCode: c) }
        return local?.share
    }
    public var isProcessing: Bool {
        if let l = local, !l.isFinished, !l.cancelled { return true }
        return remote?.transcription_status == "processing" || (remote?.status == "pending")
    }
    public var hasTranscript: Bool {
        remote?.transcription_status == "done" || (local?.transcriptStage == .done && Pipeline.isUsableTranscript(local?.transcript))
    }
    public var transcript: String? { remote?.transcript ?? local?.transcript }
}

public enum LibraryQuery {
    /// Merges server recordings with local queue items (matched by recording id) for one account.
    public static func merge(remote: [RemoteRecording], local: [QueueItem]) -> [LibraryEntry] {
        var byRid: [String: QueueItem] = [:]
        var unmatched: [QueueItem] = []
        for item in local where !item.cancelled {
            if let rid = item.recordingId { byRid[rid] = item } else { unmatched.append(item) }
        }
        var out = remote.map { LibraryEntry(remote: $0, local: byRid.removeValue(forKey: $0.id)) }
        out += byRid.values.map { LibraryEntry(remote: nil, local: $0) }
        out += unmatched.map { LibraryEntry(remote: nil, local: $0) }
        return out
    }

    public static func apply(_ entries: [LibraryEntry], search: String, filter: LibraryFilter, sort: LibrarySort) -> [LibraryEntry] {
        let q = search.trimmed.lowercased()
        var r = entries.filter { e in
            switch filter {
            case .all: return true
            case .shared: return e.plays > 0
            case .transcribed: return e.hasTranscript
            case .processing: return e.isProcessing
            case .unplayed: return e.plays == 0 && e.shareUrl != nil
            }
        }
        if !q.isEmpty {
            r = r.filter { e in
                e.title.lowercased().contains(q) || (e.transcript?.lowercased().contains(q) ?? false)
            }
        }
        switch sort {
        case .newest: r.sort { $0.date > $1.date }
        case .oldest: r.sort { $0.date < $1.date }
        case .mostPlayed: r.sort { ($0.plays, $0.date) > ($1.plays, $1.date) }
        case .longest: r.sort { $0.duration > $1.duration }
        case .title: r.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return r
    }
}
