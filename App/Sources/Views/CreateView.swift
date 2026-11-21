import SwiftUI
import HearMeOutCore

struct CreateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    DestinationBar()
                        .padding(.bottom, geo.size.height > 700 ? 30 : 16)
                    switch model.recorder.state {
                    case .finished(let take):
                        ReviewCard(take: take).frame(maxWidth: 620).transition(.scale(scale: 0.96).combined(with: .opacity))
                    default:
                        RecordingStage(compact: geo.size.height < 680)
                    }
                    Spacer(minLength: 20)
                    RecentStrip().frame(maxWidth: 760)
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, 28)
                .frame(minHeight: geo.size.height)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.recorder.state)
    }
}

// MARK: - Destination & microphone

/// Always shows where the recording will be saved and which microphone is used.
struct DestinationBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var showMics = false

    var body: some View {
        let recordingAccount = model.recorder.recordingAccountId.flatMap { model.account($0) }
        let destination = recordingAccount ?? model.activeAccount
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                AvatarView(account: destination, size: 22)
                (Text(model.recorder.isActive ? "Recording to " : "Saving to ").foregroundColor(theme.palette.secondaryText)
                 + Text(destination?.title ?? "no account").foregroundColor(theme.palette.text).bold())
                    .font(.system(size: 12.5, design: .rounded))
            }
            .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
            .background(Capsule().fill(theme.palette.surface))
            .overlay(Capsule().strokeBorder(theme.palette.stroke))
            .accessibilityElement(children: .combine)

            Button { showMics.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.devices.current?.symbol ?? "mic.slash").font(.system(size: 11, weight: .semibold))
                    Text(model.devices.current?.name ?? "No microphone").font(.system(size: 12.5, weight: .medium, design: .rounded)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(theme.palette.secondaryText)
                }
                .foregroundStyle(theme.palette.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(theme.palette.surface))
                .overlay(Capsule().strokeBorder(theme.palette.stroke))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300)
            .popover(isPresented: $showMics, arrowEdge: .bottom) {
                MicrophonePicker().environmentObject(model).environment(\.hmoTheme, theme)
            }
            .help("Choose microphone")
            .accessibilityLabel("Microphone: \(model.devices.current?.name ?? "none"). Change microphone.")
        }
        if let recordingAccount, recordingAccount.id != model.activeAccountId {
            Label("You switched accounts while recording. This recording stays with \(recordingAccount.title) unless you change it before saving.",
                  systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 12)).foregroundStyle(theme.palette.warning).padding(.top, 8)
        }
    }
}

struct MicrophonePicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Microphone").font(theme.titleFont(17))
                Spacer()
                IconButton(symbol: "arrow.clockwise", size: 24, help: "Refresh devices") { model.devices.refresh() }
            }
            if let notice = model.devices.fallbackNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(theme.palette.warning)
            }
            if model.recorder.isActive {
                Label("A new choice applies to your next recording — switching mid-recording could drop audio.", systemImage: "info.circle")
                    .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
            }
            ForEach(model.devices.devices) { d in
                let selected = d.id == model.devices.current?.id
                Button {
                    model.devices.preferredId = d.id
                    model.devices.refresh()
                    restartMonitor()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: d.symbol).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.accent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(selected ? theme.palette.accent : theme.palette.accentSoft))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.palette.text).lineLimit(1)
                            Text(d.kindLabel + (d.isSystemDefault ? " · System default" : ""))
                                .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                        }
                        Spacer()
                        if selected {
                            if model.recorder.state == .monitoring || model.recorder.state == .recording {
                                LevelDots(meter: model.recorder.meter)
                            }
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.palette.accent)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? theme.palette.accentSoft : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            if model.devices.devices.isEmpty {
                Text("No microphones found. Connect one, or check System Settings → Sound → Input.")
                    .font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
            }
            Text("Live levels use the microphone, so macOS shows its orange indicator while this is open.")
                .font(.system(size: 10.5)).foregroundStyle(theme.palette.secondaryText.opacity(0.8))
        }
        .padding(14)
        .frame(width: 330)
        .background(ThemeBackdrop(showMotif: false))
        .onAppear(perform: restartMonitor)
        .onDisappear { model.recorder.stopMonitoring() }
    }

    private func restartMonitor() {
        guard !model.recorder.isActive, RecordingController.permission == .authorized,
              let d = model.devices.captureDevice(for: model.devices.current) else { return }
        model.recorder.stopMonitoring()
        model.recorder.startMonitoring(device: d)
    }
}

struct LevelDots: View {
    @ObservedObject var meter: RecorderMeter
    @Environment(\.hmoTheme) private var theme
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule().fill(Float(i) / 5 < meter.level ? theme.palette.accent : theme.palette.secondaryText.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2.5)
            }
        }
        .animation(.linear(duration: 0.08), value: meter.level)
    }
}

// MARK: - Recording stage

struct RecordingStage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    var compact = false

    var body: some View {
        let state = model.recorder.state
        let active = state == .recording || state == .paused || state == .starting
        VStack(spacing: compact ? 16 : 24) {
            RecordOrb(state: state, meter: model.recorder.meter, size: compact ? 138 : 172) { model.toggleRecording() }
            TimerReadout(meter: model.recorder.meter, state: state)
            LiveWaveform(meter: model.recorder.meter, active: active)
                .frame(height: compact ? 54 : 70)
                .frame(maxWidth: 560)
            if active {
                HStack(spacing: 12) {
                    Button(role: .destructive) { model.recorder.discardActive() } label: { Label("Discard", systemImage: "trash") }
                        .buttonStyle(.pill(.quiet))
                    if state == .paused {
                        Button { model.recorder.resume() } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.pill(.secondary, large: true))
                            .keyboardShortcut("p", modifiers: .command)
                    } else {
                        Button { model.recorder.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.pill(.secondary, large: true))
                            .keyboardShortcut("p", modifiers: .command)
                            .disabled(state == .starting)
                    }
                    Button { model.recorder.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.pill(.record, large: true))
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                VStack(spacing: 12) {
                    if case .failed(let message) = state {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(theme.palette.record)
                            .multilineTextAlignment(.center).frame(maxWidth: 460)
                    }
                    Text("Click the microphone or press Space to start · \(model.settings.recordShortcut?.display ?? "") from anywhere")
                        .font(.system(size: 12.5, design: .rounded)).foregroundStyle(theme.palette.secondaryText)
                    Button { model.presentImportPanel() } label: { Label("Import audio…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.pill(.secondary))
                        .keyboardShortcut("o", modifiers: .command)
                    Text("or drop audio files anywhere in this window")
                        .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText.opacity(0.8))
                }
                .transition(.opacity)
            }
        }
    }
}

/// The big microphone button. Breathes gently when idle; pulses with your voice while recording.
struct RecordOrb: View {
    let state: RecordingController.State
    @ObservedObject var meter: RecorderMeter
    var size: CGFloat = 172
    let action: () -> Void
    @Environment(\.hmoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var hovering = false

    var body: some View {
        let p = theme.palette
        let recording = state == .recording
        let paused = state == .paused
        let base = recording || paused || state == .starting ? p.record : p.accent
        let level = CGFloat(recording ? meter.level : 0)
        ZStack {
            // Voice rings
            ForEach(0..<3) { i in
                Circle()
                    .fill(base.opacity(recording ? 0.16 - Double(i) * 0.04 : 0.08 - Double(i) * 0.02))
                    .frame(width: size, height: size)
                    .scaleEffect(1 + CGFloat(i + 1) * (recording ? 0.14 + level * 0.22 : (breathe ? 0.09 : 0.05)))
            }
            Circle()
                .fill(RadialGradient(colors: [base.opacity(0.95), base], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 4, endRadius: size * 0.7))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1.5))
                .shadow(color: base.opacity(0.45), radius: hovering ? 28 : 20, y: 10)
                .frame(width: size, height: size)
                .scaleEffect(hovering && !recording ? 1.03 : 1)
            Group {
                if state == .starting {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: recording ? "stop.fill" : paused ? "pause.fill" : "mic.fill")
                        .font(.system(size: size * (recording ? 0.24 : 0.3), weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .frame(width: size * 1.7, height: size * 1.7)
        .contentShape(Circle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: meter.level)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovering)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .background(
            Button("", action: action).keyboardShortcut(.space, modifiers: []).opacity(0).allowsHitTesting(false)
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(recording ? "Stop recording" : paused ? "Stop recording (paused)" : "Start recording")
        .accessibilityAction(action)
    }
}

struct TimerReadout: View {
    @ObservedObject var meter: RecorderMeter
    let state: RecordingController.State
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        let remaining = max(0, HMOLimits.maxRecordingSeconds - meter.elapsed)
        VStack(spacing: 4) {
            Text(meter.elapsed.clockText)
                .font(.system(size: 54, weight: .light, design: theme.theme.titleDesign == .serif ? .serif : .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.palette.text)
                .contentTransition(.numericText())
            Group {
                switch state {
                case .recording:
                    Label(remaining < 60 ? "\(Int(remaining)) seconds left" : "Recording · \(remaining.clockText) left",
                          systemImage: "circle.fill")
                        .foregroundStyle(remaining < 60 ? theme.palette.record : theme.palette.secondaryText)
                case .paused: Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(theme.palette.warning)
                case .starting: Text("Starting microphone…").foregroundStyle(theme.palette.secondaryText)
                default: Text("Up to 15 minutes").foregroundStyle(theme.palette.secondaryText)
                }
            }
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .labelStyle(TightLabelStyle())
        }
        .accessibilityElement(children: .combine)
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 8)); configuration.title }
    }
}

struct LiveWaveform: View {
    @ObservedObject var meter: RecorderMeter
    let active: Bool
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        WaveformBars(levels: active ? meter.history : meter.history.map { _ in 0.02 }, barWidth: 4, spacing: 3.5, minHeight: 3)
            .opacity(active ? 1 : 0.5)
            .animation(.linear(duration: 0.05), value: meter.history)
    }
}

// MARK: - Review

/// After Stop: listen back, name it, confirm the account, then Save (upload starts immediately).
struct ReviewCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let take: Take
    @StateObject private var player = AudioPlayer()
    @State private var title = ""
    @State private var destinationId = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let destination = model.account(destinationId) ?? model.account(take.accountId)
        GlassCard(padding: 24, radius: 30, strong: true) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your recording").font(theme.titleFont(24))
                        Text("\(take.duration.clockText) · \(take.recordedAt.friendlyText) · \(take.deviceName)")
                            .font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
                    }
                    Spacer()
                }
                if let note = take.note {
                    Label(note, systemImage: "info.circle.fill").font(.system(size: 12)).foregroundStyle(theme.palette.warning)
                }
                PlayerStrip(player: player)
                VStack(alignment: .leading, spacing: 6) {
                    TextField(titlePlaceholder(destination), text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(titleFocused ? theme.palette.accent : theme.palette.stroke))
                        .focused($titleFocused)
                        .onSubmit { save(destination) }
                    Text("Leave blank to let your title setting name it. A title you type is never replaced.")
                        .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                }
                HStack(spacing: 10) {
                    Menu {
                        ForEach(model.accounts) { a in
                            Button {
                                destinationId = a.id
                            } label: { Text(a.title + (a.id == take.accountId ? " (recorded here)" : "")) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            AvatarView(account: destination, size: 20)
                            Text(destination?.title ?? "Choose account").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("The account this recording will be saved to")
                    if let destination {
                        StatusPill(text: "\(destination.preferences.transcription.label) · \(destination.preferences.titleProvider.label)", symbol: "wand.and.stars", tone: .accent)
                            .help(destination.preferences.privacySummary)
                    }
                    Spacer()
                }
                if destinationId != take.accountId, let d = destination {
                    Label("This will be saved to \(d.title), not \(model.account(take.accountId)?.title ?? "the account you recorded with").",
                          systemImage: "arrow.triangle.swap")
                        .font(.system(size: 12)).foregroundStyle(theme.palette.warning)
                }
                HStack {
                    Button(role: .destructive) { player.stop(); model.discardTake() } label: { Label("Discard", systemImage: "trash") }
                        .buttonStyle(.pill(.destructive))
                    Spacer()
                    Button { player.stop(); model.discardTake(); model.startRecording() } label: { Label("Record again", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.pill(.quiet))
                    Button { save(destination) } label: { Label("Save & Share", systemImage: "arrow.up.circle.fill") }
                        .buttonStyle(.pill(.primary, large: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(destination == nil)
                }
            }
        }
        .onAppear {
            destinationId = take.accountId
            player.load(take.url, knownDuration: take.duration, readPeaks: true)
            titleFocused = true
        }
    }

    private func titlePlaceholder(_ a: Account?) -> String {
        guard let a else { return "Title (optional)" }
        switch (a.preferences.transcription, a.preferences.titleProvider) {
        case (.none, _), (_, .manual): return "Title (optional — otherwise named by date)"
        case (_, let p): return "Title (optional — \(p.label) will suggest one)"
        }
    }

    private func save(_ destination: Account?) {
        guard let destination else { return }
        player.stop()
        model.save(take: take, title: title, to: destination.id)
    }
}

/// Play/pause, waveform scrubber, time and speed.
struct PlayerStrip: View {
    @ObservedObject var player: AudioPlayer
    @Environment(\.hmoTheme) private var theme
    var showSpeed = true

    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.palette.accent))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(player.url == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    if player.peaks.isEmpty {
                        Capsule().fill(theme.palette.secondaryText.opacity(0.18)).frame(height: 6)
                        Capsule().fill(theme.waveGradient).frame(width: max(6, geo.size.width * player.progress), height: 6)
                    } else {
                        WaveformBars(levels: player.peaks, progress: player.progress, barWidth: 3, spacing: 2, minHeight: 2)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(fraction: Double(max(0, min(1, v.location.x / geo.size.width))))
                })
            }
            .frame(height: 40)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(player.currentTime.clockText) of \(player.duration.clockText)")
            .accessibilityAdjustableAction { dir in player.skip(dir == .increment ? 5 : -5) }
            Text("\(player.currentTime.clockText) / \(player.duration.clockText)")
                .font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(theme.palette.secondaryText)
                .frame(minWidth: 78, alignment: .trailing)
            if showSpeed {
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { r in
                        Button(String(format: r == 1 ? "Normal speed" : "%.2g×", r)) { player.rate = r }
                    }
                } label: {
                    Text(player.rate == 1 ? "1×" : String(format: "%.2g×", player.rate))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed")
            }
        }
    }
}

// MARK: - Recent

struct RecentStrip: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        let items = Array(model.engine.items.filter { $0.accountId == model.activeAccountId && !$0.cancelled }.prefix(3))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(theme.palette.secondaryText)
                    Spacer()
                    Button("See all") { model.tab = .library }.buttonStyle(.pill(.quiet))
                }
                HStack(spacing: 12) {
                    ForEach(items) { item in RecentCard(item: item) }
                }
            }
        }
    }
}

struct RecentCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let item: QueueItem

    var body: some View {
        GlassCard(padding: 14, radius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.displayTitle).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                Text("\(item.durationSeconds.clockText) · \(item.recordedAt.friendlyText)")
                    .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                HStack {
                    StatusPill(text: item.statusLabel, symbol: item.statusSymbol, tone: item.statusTone,
                               spinning: !item.isFinished && !item.needsAttention && item.upload != .ready)
                    Spacer()
                    if let links = item.share {
                        IconButton(symbol: "link", size: 26, help: "Copy link") { model.copy(.link, links: links) }
                    }
                }
                if let p = model.engine.uploadProgress[item.id], item.upload == .ticketed {
                    ProgressView(value: p).tint(theme.palette.accent).controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 240)
    }
}
