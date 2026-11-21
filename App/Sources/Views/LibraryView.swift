import SwiftUI
import HearMeOutCore

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var search = ""
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .newest

    var body: some View {
        let accountId = model.activeAccountId
        let all = model.entries(for: accountId)
        let shown = LibraryQuery.apply(all, search: search, filter: filter, sort: sort)
        let selected = shown.first { $0.id == model.selectedEntryId } ?? all.first { $0.id == model.selectedEntryId }
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header(count: all.count, accountId: accountId)
                controls
                if let err = accountId.flatMap({ model.libraryError[$0] }), all.isEmpty {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load your library", detail: err)
                } else if all.isEmpty {
                    EmptyState(symbol: "waveform", title: model.libraryLoading.contains(accountId ?? "") ? "Loading your recordings…" : "No recordings yet",
                               detail: "Record or import something and it will appear here.")
                } else if shown.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "Nothing matches", detail: "Try a different search or filter.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(shown) { entry in
                                LibraryRow(entry: entry, selected: entry.id == model.selectedEntryId) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        model.selectedEntryId = model.selectedEntryId == entry.id ? nil : entry.id
                                    }
                                }
                            }
                            if (model.library[accountId ?? ""]?.count ?? 0) >= HMOLimits.libraryPageLimit {
                                Text("Showing your latest 200 recordings — the most Hear Me Out's API returns. Older recordings are in the web app.")
                                    .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText).padding(.top, 8)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .frame(maxWidth: .infinity)

            if let selected, let accountId {
                RecordingDetail(entry: selected, accountId: accountId)
                    .frame(width: 400)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .id(selected.id)
            }
        }
    }

    private func header(count: Int, accountId: String?) -> some View {
        HStack(alignment: .bottom) {
            SectionTitle(title: "Library", subtitle: count == 0 ? nil : "\(count) recording\(count == 1 ? "" : "s") in \(model.activeAccount?.title ?? "this account")")
            Spacer()
            if let accountId {
                Button { model.refreshLibrary(accountId, quiet: false) } label: {
                    if model.libraryLoading.contains(accountId) { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.pill(.secondary))
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.palette.secondaryText)
                TextField("Search titles and transcripts", text: $search).textFieldStyle(.plain).font(.system(size: 13.5))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.palette.secondaryText) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(theme.palette.surface))
            .overlay(Capsule().strokeBorder(theme.palette.stroke))
            .frame(maxWidth: 320)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LibraryFilter.allCases) { f in Chip(title: f.label, selected: filter == f) { filter = f } }
                }
            }
            Menu {
                Picker("Sort", selection: $sort) { ForEach(LibrarySort.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline)
            } label: {
                Label(sort.label, systemImage: "arrow.up.arrow.down").font(.system(size: 12.5, weight: .semibold, design: .rounded))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct EmptyState: View {
    @Environment(\.hmoTheme) private var theme
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(theme.palette.accent)
            Text(title).font(theme.titleFont(20))
            Text(detail).font(.system(size: 13)).foregroundStyle(theme.palette.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let entry: LibraryEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: theme.palette.wave.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: entry.isProcessing ? "waveform.badge.ellipsis" : "waveform")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.system(size: 14.5, weight: .semibold, design: theme.theme.titleDesign)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(entry.date.friendlyText)
                        Text("·")
                        Text(entry.duration.clockText)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
                }
                Spacer(minLength: 8)
                badges
                if hovering, let links = entry.links {
                    IconButton(symbol: "link", size: 28, help: "Copy link") { model.copy(.link, links: links) }
                    IconButton(symbol: "envelope", size: 28, help: "Copy for Gmail") { model.copy(.gmail, links: links) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(selected ? theme.palette.accentSoft : (hovering ? theme.palette.surfaceStrong : theme.palette.surface)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? theme.palette.accent.opacity(0.5) : theme.palette.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if let links = entry.links {
                ForEach(ShareFormat.allCases) { f in Button(f.action) { model.copy(f, links: links) } }
                Divider()
                Button("Open in Browser") { if let u = URL(string: links.shareUrl) { NSWorkspace.shared.open(u) } }
            }
        }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if let l = entry.local, !l.isFinished, !l.cancelled {
                StatusPill(text: l.statusLabel, symbol: l.statusSymbol, tone: l.statusTone, spinning: !l.needsAttention)
            } else if entry.remote?.transcription_status == "processing" {
                StatusPill(text: "Transcribing", tone: .accent, spinning: true)
            }
            if entry.hasTranscript { StatusPill(text: "Transcript", symbol: "text.alignleft", tone: .neutral) }
            if entry.links != nil {
                StatusPill(text: entry.plays == 0 ? "Not played" : "\(entry.plays) play\(entry.plays == 1 ? "" : "s")",
                           symbol: entry.plays == 0 ? "ear" : "ear.fill", tone: entry.plays == 0 ? .neutral : .success)
            }
        }
    }
}

// MARK: - Detail

struct RecordingDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let entry: LibraryEntry
    let accountId: String
    @State private var loadingAudio = false
    @State private var audioUnavailable = false
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        let rid = entry.remote?.id ?? entry.local?.recordingId
        let detail = rid.flatMap { model.details[$0] }
        let transcript = detail?.transcript ?? entry.transcript
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        if renaming, let local = entry.local {
                            TextField("Title", text: $newTitle)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.engine.rename(local.id, to: newTitle); renaming = false }
                        } else {
                            Text(entry.title).font(theme.titleFont(22)).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Text("\(entry.date.friendlyText) · \(entry.duration.clockText)")
                            .font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
                    }
                    Spacer()
                    IconButton(symbol: "xmark", size: 26, help: "Close") { withAnimation { model.selectedEntryId = nil } }
                }
                if entry.local != nil && !renaming {
                    Button { newTitle = entry.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }.buttonStyle(.pill(.quiet))
                }

                GlassCard(padding: 14, radius: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.libraryPlayer.url != nil {
                            PlayerStrip(player: model.libraryPlayer)
                        } else if loadingAudio {
                            HStack { ProgressView().controlSize(.small); Text("Preparing audio…").font(.system(size: 12)) }
                        } else if audioUnavailable {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Audio isn't stored on this Mac.").font(.system(size: 12.5, weight: .semibold))
                                Text("Listen on the web, or ask for the Mac playback endpoint to be enabled (see the backend notes).")
                                    .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
                                if let s = entry.shareUrl, let u = URL(string: s) {
                                    Button { NSWorkspace.shared.open(u) } label: { Label("Listen in browser", systemImage: "safari") }.buttonStyle(.pill(.secondary))
                                }
                            }
                        } else {
                            Button { Task { await loadAudio() } } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.pill(.primary))
                        }
                    }
                }

                if let links = entry.links {
                    SharePanel(links: links)
                } else if let l = entry.local {
                    GlassCard(padding: 14, radius: 20) {
                        Label(l.needsAttention ? (l.lastError ?? "Needs attention") : "The share link appears as soon as Hear Me Out confirms the upload.",
                              systemImage: l.needsAttention ? "exclamationmark.triangle.fill" : "hourglass")
                            .font(.system(size: 12.5)).foregroundStyle(l.needsAttention ? theme.palette.record : theme.palette.secondaryText)
                    }
                }

                StatsRow(entry: entry, detail: detail)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcript").font(.system(size: 13, weight: .semibold, design: .rounded))
                        Spacer()
                        if let t = transcript, Pipeline.isUsableTranscript(t) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(t, forType: .string)
                                model.showToast("Transcript copied", symbol: "doc.on.doc")
                            } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.pill(.quiet))
                        }
                    }
                    if let t = transcript, !t.isEmpty {
                        Text(t).font(.system(size: 13.5, design: theme.theme.titleDesign == .serif ? .serif : .default))
                            .lineSpacing(4).textSelection(.enabled).foregroundStyle(theme.palette.text.opacity(0.9))
                    } else {
                        Text(transcriptPlaceholder).font(.system(size: 12.5)).foregroundStyle(theme.palette.secondaryText)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.never)
        .background(
            Rectangle().fill(.ultraThinMaterial).overlay(Rectangle().fill(theme.palette.surface)).ignoresSafeArea()
                .overlay(alignment: .leading) { Rectangle().fill(theme.palette.stroke).frame(width: 1) }
        )
        .onAppear {
            model.loadDetail(entry, accountId: accountId)
            Task { await loadAudio(autoplay: false) }
        }
        .onDisappear { model.libraryPlayer.stop() }
    }

    private var transcriptPlaceholder: String {
        if let l = entry.local {
            switch l.transcriptStage {
            case .running: return "Transcribing on this Mac…"
            case .pending: return l.preferences.transcription == .cloud ? "Waiting for Hear Me Out's transcript…" : "Transcription is queued."
            case .failed: return l.lastError ?? "Transcription failed."
            case .notNeeded: return "No transcript was requested for this recording."
            case .done: return "No speech was detected."
            }
        }
        switch entry.remote?.transcription_status {
        case "processing": return "Hear Me Out is transcribing this recording…"
        case "failed": return "Cloud transcription failed."
        default: return "No transcript."
        }
    }

    private func loadAudio(autoplay: Bool = true) async {
        loadingAudio = true
        defer { loadingAudio = false }
        if let url = await model.playbackURL(for: entry, accountId: accountId) {
            model.libraryPlayer.load(url, knownDuration: entry.duration, readPeaks: url.isFileURL)
            if autoplay { model.libraryPlayer.toggle() }
        } else if autoplay || entry.local == nil || entry.local?.audioRemoved == true {
            audioUnavailable = model.playbackAvailable == false || entry.remote != nil
        }
    }
}

struct StatsRow: View {
    @Environment(\.hmoTheme) private var theme
    let entry: LibraryEntry
    let detail: RemoteRecording?

    var body: some View {
        let r = detail ?? entry.remote
        HStack(spacing: 10) {
            stat("Plays", "\(r?.plays ?? 0)", "ear.fill")
            stat("First played", ISODate.parse(r?.first_played_at)?.friendlyText ?? "Not yet", "clock.fill")
            stat("Last played", ISODate.parse(r?.last_played_at)?.friendlyText ?? "—", "clock.arrow.circlepath")
        }
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.palette.secondaryText)
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.palette.surface))
    }
}

/// Copy Link · Copy for Gmail · Copy HTML Embed · Copy Message · Open in Browser. Never sends anything itself.
struct SharePanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let links: ShareLinks

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share").font(.system(size: 13, weight: .semibold, design: .rounded))
            let preferred = model.settings.preferredShareFormat
            Button { model.copy(preferred, links: links) } label: {
                HStack {
                    Image(systemName: preferred.symbol)
                    Text(preferred.action)
                    Spacer()
                    Text("⌘C").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.7)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill(.primary, large: true))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ShareFormat.allCases.filter { $0 != preferred }) { f in
                    Button { model.copy(f, links: links) } label: {
                        Label(f.action, systemImage: f.symbol).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pill(.secondary))
                }
                Button { if let u = URL(string: links.shareUrl) { NSWorkspace.shared.open(u) } } label: {
                    Label("Open in Browser", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.secondary))
            }
            Text(links.shareUrl).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.palette.secondaryText)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ImportCandidate] = []
    @State private var accountId = ""
    @State private var transcription: TranscriptionMode = .local
    @State private var titleProvider: TitleProvider = .hearMeOut
    @State private var working = false
    @StateObject private var player = AudioPlayer()
    @State private var previewing: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import audio").font(theme.titleFont(24))
                Spacer()
                Text("\(items.filter(\.canUpload).count) of \(items.count) ready").font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($items) { $item in
                        ImportRow(item: $item, isPreviewing: previewing == item.id) {
                            if previewing == item.id { player.toggle() } else {
                                previewing = item.id
                                player.load(item.sourceURL, knownDuration: item.duration, readPeaks: false)
                                player.toggle()
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 380)

            GlassCard(padding: 14, radius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Upload to").font(.system(size: 12.5, weight: .semibold))
                        Picker("", selection: $accountId) {
                            ForEach(model.accounts) { a in Text(a.title).tag(a.id) }
                        }
                        .labelsHidden().frame(maxWidth: 240)
                    }
                    HStack {
                        Text("Transcript").font(.system(size: 12.5, weight: .semibold))
                        Picker("", selection: $transcription) { ForEach(TranscriptionMode.allCases) { Text($0.label).tag($0) } }
                            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 360)
                    }
                    if transcription != .none {
                        HStack {
                            Text("Title").font(.system(size: 12.5, weight: .semibold))
                            Picker("", selection: $titleProvider) { ForEach(TitleProvider.allCases) { Text($0.label).tag($0) } }
                                .labelsHidden().frame(maxWidth: 240)
                        }
                    }
                    Text(ProcessingPreferences(transcription: transcription, titleProvider: titleProvider).privacySummary)
                        .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
                }
            }
            HStack {
                Button("Cancel") { player.stop(); model.importCandidates = []; dismiss() }.buttonStyle(.pill(.quiet))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    working = true
                    player.stop()
                    Task {
                        await model.commitImports(items, accountId: accountId, preferences: .init(transcription: transcription, titleProvider: titleProvider))
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Label("Upload", systemImage: "arrow.up.circle.fill") }
                }
                .buttonStyle(.pill(.primary, large: true))
                .disabled(working || accountId.isEmpty || !items.contains(where: \.canUpload))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(ThemeBackdrop(showMotif: false))
        .onAppear {
            items = model.importCandidates
            accountId = model.activeAccountId ?? model.accounts.first?.id ?? ""
            if let a = model.account(accountId) {
                transcription = a.preferences.transcription
                titleProvider = a.preferences.titleProvider
            }
        }
        .onChange(of: accountId) { _, id in
            if let a = model.account(id) { transcription = a.preferences.transcription; titleProvider = a.preferences.titleProvider }
        }
    }
}

struct ImportRow: View {
    @Environment(\.hmoTheme) private var theme
    @Binding var item: ImportCandidate
    let isPreviewing: Bool
    let preview: () -> Void

    var body: some View {
        GlassCard(padding: 12, radius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button(action: preview) {
                        Image(systemName: isPreviewing ? "speaker.wave.2.fill" : "play.fill").frame(width: 30, height: 30)
                            .background(Circle().fill(theme.palette.accentSoft))
                    }
                    .buttonStyle(.plain)
                    .disabled(!AudioFormat.isLocallyDecodable(item.ext))
                    TextField("Title", text: $item.title).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(item.duration.clockText) · \(item.sizeBytes.fileSizeText) · .\(item.ext)")
                        .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                }
                HStack(spacing: 8) {
                    DatePicker("Recorded", selection: Binding(get: { item.recordedAt }, set: { item.recordedAt = $0; item.dateSource = .manual }),
                               in: RecordedAt.earliest...Date(), displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact).font(.system(size: 12)).fixedSize()
                    Text(item.dateSourceText).font(.system(size: 11))
                        .foregroundStyle(item.dateSource == .metadata || item.dateSource == .manual ? theme.palette.secondaryText : theme.palette.warning)
                }
                if let c = item.conversion { Label(c, systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText) }
                if let p = item.problem { Label(p, systemImage: "xmark.octagon.fill").font(.system(size: 11.5)).foregroundStyle(theme.palette.record) }
            }
        }
    }
}
