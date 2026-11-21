import SwiftUI
import HearMeOutCore

/// Seven quick steps: welcome, accounts, theme, microphone, transcription, titles, ready.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var step = 0
    @State private var forward = true
    private let steps = ["Welcome", "Accounts", "Theme", "Microphone", "Transcription", "Titles", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 64, height: 1)
                BrandMark()
                Spacer()
                if step > 0 && step < steps.count - 1 && !model.accounts.isEmpty {
                    Button("Skip setup") { model.finishOnboarding() }.buttonStyle(.pill(.quiet))
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).frame(height: 58)

            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: 760, maxHeight: .infinity)
            .padding(.horizontal, 30)

            HStack(spacing: 16) {
                Button { go(step - 1) } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.pill(.quiet)).opacity(step == 0 ? 0 : 1).disabled(step == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule().fill(i == step ? theme.palette.accent : theme.palette.secondaryText.opacity(0.25))
                            .frame(width: i == step ? 22 : 7, height: 7)
                    }
                }
                .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(steps.count): \(steps[step])")
                Spacer()
                Button { next() } label: {
                    Label(step == steps.count - 1 ? "Start recording" : step == 0 ? "Get started" : "Continue", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabel())
                }
                .buttonStyle(.pill(.primary, large: true))
                .disabled(step == 1 && model.accounts.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30).padding(.bottom, 26)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: step)
    }

    private func go(_ s: Int) {
        forward = s > step
        step = max(0, min(steps.count - 1, s))
    }

    private func next() {
        if step == steps.count - 1 { model.finishOnboarding() } else { go(step + 1) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: StepFrame(title: "Connect your accounts", subtitle: "Add each authorised Google account. You'll switch between them in one click.") { OnboardingAccounts() }
        case 2: StepFrame(title: "Pick a look", subtitle: model.activeAccount.map { "This theme is for \($0.title). Each account can have its own." } ?? "Choose a theme.") {
            ScrollView { ThemeGallery(compact: true) }.scrollIndicators(.never)
        }
        case 3: StepFrame(title: "Choose your microphone", subtitle: "You can change it any time from the recording screen.") { OnboardingMicrophone() }
        case 4: StepFrame(title: "Transcription", subtitle: "Private and on-device by default.") { OnboardingTranscription() }
        case 5: StepFrame(title: "Titles", subtitle: "Who should name your recordings?") { OnboardingTitles() }
        default: ReadyStep()
        }
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

struct StepFrame<Content: View>: View {
    @Environment(\.hmoTheme) private var theme
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(theme.titleFont(34))
                Text(subtitle).font(.system(size: 14)).foregroundStyle(theme.palette.secondaryText)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }
}

struct WelcomeStep: View {
    @Environment(\.hmoTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(theme.palette.accent.opacity(0.18 - Double(i) * 0.05), lineWidth: 1.5)
                        .frame(width: 150 + CGFloat(i) * 60, height: 150 + CGFloat(i) * 60)
                        .scaleEffect(appear ? 1 : 0.85)
                }
                Circle().fill(LinearGradient(colors: theme.palette.wave, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 128, height: 128)
                    .shadow(color: theme.palette.accent.opacity(0.4), radius: 26, y: 12)
                HStack(spacing: 5) {
                    ForEach([0.4, 0.75, 0.55, 1.0, 0.65, 0.35], id: \.self) { h in
                        Capsule().fill(.white).frame(width: 6, height: 56 * h)
                    }
                }
            }
            .frame(height: 280)
            Text("Hear Me Out").font(theme.titleFont(48, weight: .bold))
            Text("Record a voice note, and share it in seconds.\nBeautiful links, Gmail-ready cards and transcripts — straight from your Mac.")
                .font(.system(size: 16)).multilineTextAlignment(.center).foregroundStyle(theme.palette.secondaryText).lineSpacing(3)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.7)) { appear = true } }
    }
}

struct OnboardingAccounts: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { AccountsSettings() }
        }
        .scrollIndicators(.never)
    }
}

struct OnboardingMicrophone: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.devices.devices) { d in
                        OptionCard(title: d.name, detail: d.kindLabel + (d.isSystemDefault ? " · System default" : ""), symbol: d.symbol,
                                   selected: d.id == model.devices.current?.id) {
                            model.devices.preferredId = d.id
                            model.devices.refresh()
                            if testing { startTest() }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack(spacing: 14) {
                Button(testing ? "Stop test" : "Test microphone") { testing ? stopTest() : startTest() }.buttonStyle(.pill(.secondary))
                if testing {
                    LiveWaveform(meter: model.recorder.meter, active: true).frame(height: 40)
                } else {
                    Text("Speak to see your level.").font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
                }
            }
        }
        .onDisappear(perform: stopTest)
    }

    private func startTest() {
        Task {
            guard await RecordingController.requestPermission(), let d = model.devices.captureDevice(for: model.devices.current) else { return }
            model.recorder.stopMonitoring()
            model.recorder.startMonitoring(device: d)
            testing = true
        }
    }

    private func stopTest() {
        model.recorder.stopMonitoring()
        testing = false
    }
}

struct OnboardingTranscription: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TranscriptionMode.allCases) { mode in
                    OptionCard(title: mode.label, detail: mode.explanation,
                               symbol: mode == .local ? "laptopcomputer" : mode == .cloud ? "cloud.fill" : "speaker.wave.2.fill",
                               selected: model.settings.defaultPreferences.transcription == mode, badge: mode == .local ? "Recommended" : nil) {
                        setAll { $0.transcription = mode }
                    }
                }
                if model.settings.defaultPreferences.transcription == .local {
                    ModelSettingsCard()
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func setAll(_ change: (inout ProcessingPreferences) -> Void) {
        change(&model.settings.defaultPreferences)
        for a in model.accounts { model.updateAccount(a.id) { change(&$0.preferences) } }
    }
}

struct OnboardingTitles: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let apple = AppleTitleGenerator.availability
        VStack(alignment: .leading, spacing: 10) {
            ForEach(TitleProvider.allCases) { p in
                OptionCard(title: p.label, detail: p.explanation,
                           symbol: p == .appleIntelligence ? "sparkles" : p == .openAI ? "brain" : p == .hearMeOut ? "cloud.fill" : "pencil",
                           selected: model.settings.defaultPreferences.titleProvider == p,
                           disabledReason: p == .appleIntelligence ? appleReason(apple)
                                : (p == .openAI ? "You'll add your OpenAI key in Settings → AI Titles." : nil)) {
                    model.settings.defaultPreferences.titleProvider = p
                    for a in model.accounts { model.updateAccount(a.id) { $0.preferences.titleProvider = p } }
                }
            }
        }
    }
}

private func appleReason(_ a: AppleTitleGenerator.Availability) -> String? {
    if case .unavailable(let why) = a { return why }
    return nil
}

struct ReadyStep: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(theme.palette.accent)
            Text("You're all set").font(theme.titleFont(40, weight: .bold))
            VStack(spacing: 6) {
                Text("Press \(model.settings.recordShortcut?.display ?? "the microphone") from anywhere to record.")
                Text("Your link is ready moments after you save — transcripts and titles follow.")
            }
            .font(.system(size: 15)).foregroundStyle(theme.palette.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
