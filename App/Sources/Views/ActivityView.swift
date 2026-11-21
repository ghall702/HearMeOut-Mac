import SwiftUI
import HearMeOutCore

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        let items = model.engine.items.filter { !$0.cancelled }
        let attention = items.filter { $0.needsAttention || ($0.isFinished && $0.lastError != nil) }
        let active = items.filter { !$0.isFinished && !$0.needsAttention }
        let done = items.filter { $0.isFinished && $0.lastError == nil }.prefix(30)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    SectionTitle(title: "Activity", subtitle: subtitle(active: active.count))
                    Spacer()
                    if !model.connectivity.isOnline {
                        StatusPill(text: "Offline — uploads resume automatically", symbol: "wifi.slash", tone: .warning)
                    }
                }
                if items.isEmpty {
                    EmptyState(symbol: "checkmark.circle", title: "All caught up", detail: "Uploads, transcriptions and titles appear here while they run.")
                        .frame(height: 360)
                }
                if !attention.isEmpty { group("Needs your attention", attention) }
                if !active.isEmpty { group("In progress", Array(active)) }
                if !done.isEmpty { group("Recently finished", Array(done)) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private func subtitle(active: Int) -> String {
        active == 0 ? "Nothing running right now. Work carries on in the background, even with the window closed." :
            "\(active) item\(active == 1 ? "" : "s") processing in the background — carry on as normal."
    }

    private func group(_ title: String, _ items: [QueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.palette.secondaryText)
            ForEach(items) { ActivityCard(item: $0) }
        }
    }
}

struct ActivityCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let item: QueueItem

    var body: some View {
        GlassCard(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AvatarView(account: model.account(item.accountId), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text("\(model.account(item.accountId)?.title ?? "Removed account") · \(item.recordedAt.friendlyText) · \(item.durationSeconds.clockText)")
                            .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
                    }
                    Spacer()
                    StatusPill(text: item.statusLabel, symbol: item.statusSymbol, tone: item.statusTone)
                }
                StepTrack(item: item)
                if item.upload == .ticketed, let p = model.engine.uploadProgress[item.id] {
                    ProgressView(value: p) { Text("Uploading \(Int(p * 100))%").font(.system(size: 11)) }.tint(theme.palette.accent)
                }
                if item.transcriptStage == .running, let p = model.engine.transcriptionProgress[item.id] {
                    ProgressView(value: p) { Text("Transcribing on this Mac · \(Int(p * 100))%").font(.system(size: 11)) }.tint(theme.palette.accent)
                }
                if let e = item.lastError {
                    Label(e, systemImage: item.needsAttention ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(item.needsAttention ? theme.palette.record : theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let next = item.nextAttemptAt, next > Date(), !item.isFinished {
                    Text("Trying again \(next.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                }
                if model.account(item.accountId)?.needsReconnect == true {
                    HStack {
                        Label("This account needs reconnecting before uploads can continue.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 12)).foregroundStyle(theme.palette.warning)
                        Spacer()
                        Button("Reconnect") { model.tab = .settings; model.settingsSection = .accounts }.buttonStyle(.pill(.primary))
                    }
                }
                actions
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let links = item.share {
                Button { model.copy(model.settings.preferredShareFormat, links: links) } label: {
                    Label(model.settings.preferredShareFormat.action, systemImage: model.settings.preferredShareFormat.symbol)
                }
                .buttonStyle(.pill(.secondary))
            }
            if item.needsAttention || item.transcriptStage == .failed || item.titleStage == .failed || item.syncStage == .failed || item.nextAttemptAt != nil {
                Button { model.engine.retryNow(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.pill(.secondary))
            }
            if item.transcriptStage == .failed && item.preferences.transcription == .local && item.upload == .ready {
                Button { model.engine.switchToCloudTranscription(item.id) } label: { Label("Transcribe in the cloud", systemImage: "cloud") }
                    .buttonStyle(.pill(.secondary))
                    .help("Sends this recording to Hear Me Out's cloud transcription instead")
            }
            if item.titleStage == .failed {
                Button { model.engine.retryTitle(item.id) } label: { Label("Retry title", systemImage: "sparkles") }.buttonStyle(.pill(.secondary))
            }
            Spacer()
            if !item.audioRemoved {
                IconButton(symbol: "folder", size: 28, help: "Show audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.audio.appendingPathComponent(item.audioFileName)])
                }
            }
            if !item.isFinished && item.upload != .ready {
                Button(role: .destructive) { model.engine.cancel(item.id) } label: { Text("Cancel") }.buttonStyle(.pill(.quiet))
            }
            if item.isFinished || item.cancelled {
                Button { model.engine.remove(item.id) } label: { Text("Clear") }.buttonStyle(.pill(.quiet))
                    .help("Removes this entry from Activity. The recording stays in Hear Me Out.")
            }
        }
    }
}

/// Upload → Share link → Transcript → Title, each with its own state.
struct StepTrack: View {
    @Environment(\.hmoTheme) private var theme
    let item: QueueItem

    enum StepState { case waiting, running, done, failed, skipped }

    var body: some View {
        HStack(spacing: 0) {
            step("Upload", uploadState, "arrow.up")
            connector
            step("Share link", item.upload == .ready ? .done : (item.upload == .uploaded ? .running : .waiting), "link")
            connector
            step("Transcript", transcriptState, "text.alignleft")
            connector
            step("Title", titleState, "sparkles")
        }
    }

    private var connector: some View {
        Rectangle().fill(theme.palette.stroke).frame(height: 1.5).frame(maxWidth: .infinity).padding(.horizontal, 4)
    }

    private var uploadState: StepState {
        if item.needsAttention && item.upload < .uploaded { return .failed }
        switch item.upload {
        case .pending: return .waiting
        case .ticketed: return .running
        case .uploaded, .ready: return .done
        }
    }

    private var transcriptState: StepState {
        switch item.transcriptStage {
        case .notNeeded: return .skipped
        case .pending: return item.cloudStage == .running || item.cloudStage == .done ? .running : .waiting
        case .running: return .running
        case .done: return .done
        case .failed: return .failed
        }
    }

    private var titleState: StepState {
        if item.userTitle != nil { return .done }
        switch item.titleStage {
        case .notNeeded:
            if item.preferences.titleProvider == .hearMeOut && item.preferences.transcription != .none {
                return item.isFinished ? .done : .waiting
            }
            return .skipped
        case .pending: return .waiting
        case .running: return .running
        case .done: return item.syncStage == .done || item.syncStage == .notNeeded ? .done : .running
        case .failed: return .failed
        }
    }

    private func step(_ label: String, _ state: StepState, _ symbol: String) -> some View {
        let p = theme.palette
        let color: Color = {
            switch state {
            case .done: return p.success
            case .running: return p.accent
            case .failed: return p.record
            case .waiting, .skipped: return p.secondaryText.opacity(0.5)
            }
        }()
        return VStack(spacing: 5) {
            ZStack {
                Circle().fill(color.opacity(state == .waiting || state == .skipped ? 0.1 : 0.18)).frame(width: 28, height: 28)
                if state == .running {
                    ProgressView().controlSize(.mini).tint(color)
                } else {
                    Image(systemName: state == .done ? "checkmark" : state == .failed ? "exclamationmark" : state == .skipped ? "minus" : symbol)
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                }
            }
            Text(label).font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(state == .skipped ? p.secondaryText.opacity(0.6) : p.secondaryText)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(String(describing: state))")
    }
}
