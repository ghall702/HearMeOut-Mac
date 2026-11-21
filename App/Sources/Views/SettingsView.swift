import SwiftUI
import HearMeOutCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(theme.titleFont(28)).padding(.bottom, 10).padding(.leading, 8)
                ForEach(SettingsSection.allCases) { s in
                    let selected = model.settingsSection == s
                    Button { withAnimation(.easeInOut(duration: 0.2)) { model.settingsSection = s } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 18)
                            Text(s.label).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            Spacer()
                        }
                        .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.text.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? theme.palette.accent : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 210)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.settingsSection {
                    case .accounts: AccountsSettings()
                    case .appearance: AppearanceSettings()
                    case .recording: RecordingSettings()
                    case .transcription: TranscriptionSettings()
                    case .titles: TitleSettings()
                    case .storage: StorageSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(.bottom, 40)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
    }
}

/// A titled card section inside Settings.
struct SettingsCard<Content: View>: View {
    @Environment(\.hmoTheme) private var theme
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(padding: 20, radius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(theme.titleFont(18))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true) }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Picks which account a per-account setting applies to.
struct AccountTargetPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var accountId: String

    var body: some View {
        if model.accounts.count > 1 {
            Picker("For", selection: $accountId) {
                ForEach(model.accounts) { a in Text(a.title).tag(a.id) }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Accounts

struct AccountsSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var showKeyEntry = false
    @State private var key = ""
    @State private var nickname = ""
    @State private var confirmRemove: Account?

    var body: some View {
        SettingsCard(title: "Your accounts", subtitle: "Up to three Hear Me Out accounts. Each keeps its own recordings, theme and settings, and its own key in your Keychain.") {
            ForEach(model.accounts) { a in
                AccountSettingsRow(account: a, confirmRemove: $confirmRemove)
            }
            if model.accounts.isEmpty {
                Text("No accounts yet.").font(.system(size: 13)).foregroundStyle(theme.palette.secondaryText)
            }
        }
        SettingsCard(title: "Add an account", subtitle: "Sign in with Google in your browser. Hear Me Out receives its own key for this Mac — never your Google password.") {
            HStack(spacing: 10) {
                Button { Task { await model.signInWithGoogle() } } label: {
                    HStack(spacing: 8) {
                        if model.signInInProgress { ProgressView().controlSize(.small) } else { Image(systemName: "person.crop.circle.badge.plus") }
                        Text("Sign in with Google")
                    }
                }
                .buttonStyle(.pill(.primary, large: true))
                .disabled(model.signInInProgress || model.nativeSignInAvailable == false)
                Button("Use an API key instead") { showKeyEntry.toggle() }.buttonStyle(.pill(.quiet))
            }
            if model.nativeSignInAvailable == false {
                Label("Google sign-in for the Mac app needs a small Hear Me Out update (see backend/README.md). Until then, connect with an API key from Hear Me Out → Settings → API keys.",
                      systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.signInError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(theme.palette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showKeyEntry || model.nativeSignInAvailable == false {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("hmo_…", text: $key).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                    TextField("Label (optional) — e.g. Work or Tutoring", text: $nickname).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Connect") {
                            Task {
                                if await model.connect(apiKey: key, nickname: nickname) { key = ""; nickname = ""; showKeyEntry = false }
                            }
                        }
                        .buttonStyle(.pill(.primary))
                        .disabled(key.isEmpty || model.signInInProgress)
                        Button("Open Hear Me Out API keys") { NSWorkspace.shared.open(URL(string: "https://hearmeout.george-hall.uk/settings")!) }
                            .buttonStyle(.pill(.quiet))
                    }
                    Text("Keys are checked with Hear Me Out, then stored only in your Keychain.").font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                }
            }
        }
        .confirmationDialog("Remove \(confirmRemove?.title ?? "account") from this Mac?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let a = confirmRemove { Task { await model.removeAccount(a.id) } }
                confirmRemove = nil
            }
        } message: {
            let pending = confirmRemove.map { model.pendingUploadCount(for: $0.id) } ?? 0
            Text(pending > 0 ? "\(pending) recording\(pending == 1 ? " is" : "s are") still uploading to this account and will wait until you reconnect it. Your recordings in Hear Me Out are not deleted."
                 : "Your recordings stay in Hear Me Out. You can sign in again at any time.")
        }
    }
}

struct AccountSettingsRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let account: Account
    @Binding var confirmRemove: Account?
    @State private var nickname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(account: account, size: 44, ring: account.id == model.activeAccountId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName ?? account.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(account.email ?? "Email unavailable (connected with an API key)").font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
                    HStack(spacing: 6) {
                        StatusPill(text: account.authMethod == .google ? "Google" : "API key", symbol: account.authMethod == .google ? "person.badge.key.fill" : "key.fill")
                        StatusPill(text: ThemeCatalog.theme(account.themeId).name, symbol: "paintpalette.fill")
                        if account.needsReconnect { StatusPill(text: "Needs reconnecting", symbol: "exclamationmark", tone: .warning) }
                        if model.settings.defaultAccountId == account.id { StatusPill(text: "Default", symbol: "star.fill", tone: .accent) }
                    }
                }
                Spacer()
                if account.id != model.activeAccountId {
                    Button("Switch") { model.switchAccount(to: account.id) }.buttonStyle(.pill(.secondary))
                }
                Menu {
                    Button("Make default account") { model.settings.defaultAccountId = account.id }
                    if account.authMethod == .google {
                        Button("Reconnect with Google") { Task { await model.signInWithGoogle(reconnecting: account) } }
                    }
                    Button("Refresh profile picture") { model.avatars.refresh(account) }
                    Divider()
                    Button("Remove from this Mac…", role: .destructive) { confirmRemove = account }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                TextField("Label (e.g. Work)", text: $nickname, onCommit: { model.updateAccount(account.id) { $0.nickname = nickname.trimmed.nonEmpty } })
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                if account.needsReconnect {
                    Button("Reconnect") {
                        if account.authMethod == .google { Task { await model.signInWithGoogle(reconnecting: account) } }
                    }
                    .buttonStyle(.pill(.primary))
                    if account.authMethod == .apiKey {
                        Text("Paste a new key below to reconnect.").font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.palette.surface))
        .onAppear { nickname = account.nickname ?? "" }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        SettingsCard(title: "Theme", subtitle: model.settings.useGlobalTheme ? "One theme for every account." :
                        "Each account has its own theme, so you always know where you are. Hover to preview, click to choose.") {
            Toggle("Use one theme for all accounts", isOn: $model.settings.useGlobalTheme)
                .toggleStyle(.switch)
            ThemeGallery()
        }
        SettingsCard(title: "Light and dark") {
            Picker("Appearance", selection: $model.settings.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Show decorative illustrations", isOn: $model.settings.decorations).toggleStyle(.switch)
            Text("Animations follow macOS's Reduce Motion setting automatically.")
                .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
        }
    }
}

struct ThemeGallery: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        let selectedId = model.settings.useGlobalTheme ? model.settings.globalThemeId : (model.activeAccount?.themeId ?? model.settings.globalThemeId)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 160), spacing: 14)], spacing: 14) {
            ForEach(ThemeCatalog.all) { t in
                ThemeCard(theme: t, scheme: model.resolvedTheme(themeId: t.id).scheme, selected: t.id == selectedId,
                          previewing: model.previewThemeId == t.id) {
                    model.applyTheme(t.id)
                } preview: {
                    withAnimation(.easeInOut(duration: 0.35)) { model.previewThemeId = t.id == selectedId ? nil : t.id }
                }
            }
        }
    }
}

/// A miniature of the whole app in that theme: backdrop, motif, orb and waveform.
struct ThemeCard: View {
    @Environment(\.hmoTheme) private var current
    let theme: Theme
    let scheme: ColorScheme
    let selected: Bool
    let previewing: Bool
    let choose: () -> Void
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        let p = theme.palette(scheme)
        let resolved = ResolvedTheme(theme: theme, scheme: scheme)
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ThemeBackdrop().environment(\.hmoTheme, resolved)
                VStack(spacing: 7) {
                    Circle().fill(p.accent).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "mic.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(p.onAccent))
                        .shadow(color: p.accent.opacity(0.4), radius: 6, y: 3)
                    HStack(spacing: 2) {
                        ForEach(0..<14, id: \.self) { i in
                            Capsule().fill(LinearGradient(colors: p.wave, startPoint: .bottom, endPoint: .top))
                                .frame(width: 3, height: 4 + CGFloat((i * 7) % 11) * 1.6)
                        }
                    }
                    Text("0:42").font(.system(size: 11, weight: .light, design: theme.titleDesign)).foregroundStyle(p.text)
                }
            }
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? current.palette.accent : Color.black.opacity(0.06), lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, current.palette.accent).padding(7)
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.name).font(.system(size: 12.5, weight: .semibold, design: theme.titleDesign)).foregroundStyle(current.palette.text)
                    Text(theme.tagline).font(.system(size: 10.5)).foregroundStyle(current.palette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: preview) {
                    Image(systemName: previewing ? "eye.fill" : "eye").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(previewing ? current.palette.accent : current.palette.secondaryText)
                .help("Preview without applying")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(theme.name) theme\(selected ? ", selected" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Preview", preview)
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        SettingsCard(title: "Microphone", subtitle: "Hear Me Out remembers your choice and falls back to the system default if it's unplugged.") {
            ForEach(model.devices.devices) { d in
                OptionCard(title: d.name, detail: d.kindLabel + (d.isSystemDefault ? " · System default" : ""), symbol: d.symbol,
                           selected: d.id == model.devices.current?.id) { model.devices.preferredId = d.id; model.devices.refresh() }
            }
            if model.devices.devices.isEmpty {
                Text("No microphones found.").font(.system(size: 12.5)).foregroundStyle(theme.palette.secondaryText)
            }
        }
        SettingsCard(title: "Quality", subtitle: "AAC in an .m4a file, 48 kHz mono. All options stay well within Hear Me Out's 500 MB limit for 15 minutes.") {
            Picker("Quality", selection: $model.settings.recordingQuality) {
                ForEach(RecordingQuality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        SettingsCard(title: "Quick access") {
            Toggle("Show Hear Me Out in the menu bar", isOn: $model.settings.showMenuBar).toggleStyle(.switch)
            ShortcutRow(action: .toggleRecording, shortcut: $model.settings.recordShortcut, conflict: model.shortcutConflicts.contains(.toggleRecording))
            ShortcutRow(action: .openApp, shortcut: $model.settings.openShortcut, conflict: model.shortcutConflicts.contains(.openApp))
            ShortcutRow(action: .copyLatestLink, shortcut: $model.settings.copyShortcut, conflict: model.shortcutConflicts.contains(.copyLatestLink))
            Text("Shortcuts work from any app and need no extra permissions. They use at least two modifier keys to avoid clashing with typing.")
                .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
        }
    }
}

struct ShortcutRow: View {
    @Environment(\.hmoTheme) private var theme
    let action: HotKeyAction
    @Binding var shortcut: Shortcut?
    let conflict: Bool
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.label).font(.system(size: 13))
            Spacer()
            if conflict { StatusPill(text: "In use by another app", symbol: "exclamationmark", tone: .warning) }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type a shortcut…" : (shortcut?.display ?? "None"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).frame(minWidth: 110)
            }
            .buttonStyle(.pill(recording ? .primary : .secondary))
            if shortcut != nil {
                IconButton(symbol: "xmark", size: 24, help: "Clear shortcut") { shortcut = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc cancels
            if let s = Shortcut(event: e) { shortcut = s; stop(); return nil }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var target = ""

    var body: some View {
        let account = model.account(target) ?? model.activeAccount
        SettingsCard(title: "How recordings are transcribed", subtitle: "Saved per account. Your choice is shown before every upload.") {
            AccountTargetPicker(accountId: $target)
            ForEach(TranscriptionMode.allCases) { mode in
                OptionCard(title: mode.label, detail: mode.explanation,
                           symbol: mode == .local ? "laptopcomputer" : mode == .cloud ? "cloud.fill" : "speaker.wave.2.fill",
                           selected: account?.preferences.transcription == mode,
                           badge: mode == .local ? "Private" : nil) {
                    if let a = account { model.updateAccount(a.id) { $0.preferences.transcription = mode } }
                }
            }
        }
        .onAppear { if target.isEmpty { target = model.activeAccountId ?? "" } }
        ModelSettingsCard()
    }
}

struct ModelSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var showDownloads = false

    var body: some View {
        ModelSettingsContent(library: model.models, showDownloads: $showDownloads)
    }
}

struct ModelSettingsContent: View {
    @ObservedObject var library: ModelLibrary
    @Binding var showDownloads: Bool
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        SettingsCard(title: "Whisper model", subtitle: "Runs on Apple Silicon with WhisperKit. Loaded only when needed and released when idle.") {
            switch library.status {
            case .ready(let m):
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(theme.palette.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.friendlyName).font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("\(originText(m.origin)) · \(m.sizeBytes.fileSizeText)").font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
                    }
                }
            case .missingShared:
                Label("The model shared from Let's Meet isn't available. Re-select its folder, or choose another model.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(theme.palette.warning)
            case .none:
                Label("No model selected yet. Reuse Let's Meet's model or download one.", systemImage: "info.circle")
                    .font(.system(size: 12.5)).foregroundStyle(theme.palette.secondaryText)
            }

            HStack(spacing: 8) {
                Button { library.requestLetsMeetAccess() } label: { Label("Find Let's Meet's model", systemImage: "magnifyingglass") }
                    .buttonStyle(.pill(.primary))
                Button { library.chooseFolder() } label: { Label("Choose a folder…", systemImage: "folder") }.buttonStyle(.pill(.secondary))
                Button { library.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(.pill(.quiet))
            }
            Text("Let's Meet Note Taker uses the same engine and model format, so its model works here as-is. macOS asks you to select its folder once; Hear Me Out only reads it — nothing is copied, changed or deleted.")
                .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let e = library.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(theme.palette.record)
            }

            if !library.models.isEmpty {
                VStack(spacing: 8) {
                    ForEach(library.models) { m in
                        HStack(spacing: 10) {
                            Image(systemName: m.format.isCompatible ? "cpu" : "xmark.octagon").foregroundStyle(m.format.isCompatible ? theme.palette.accent : theme.palette.record)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.friendlyName).font(.system(size: 13, weight: .semibold, design: .rounded))
                                Text(m.format.isCompatible ? "\(originText(m.origin)) · \(m.sizeBytes.fileSizeText)" : m.format.explanation)
                                    .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if m.format.isCompatible {
                                if library.selection?.folderPath == m.folder.path {
                                    StatusPill(text: "In use", symbol: "checkmark", tone: .success)
                                } else {
                                    Button("Use") { library.select(m) }.buttonStyle(.pill(.secondary))
                                }
                            }
                            if m.origin == .hearMeOut {
                                IconButton(symbol: "trash", size: 24, help: "Delete this downloaded model") { library.delete(m) }
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.palette.surface))
                    }
                }
            }

            DisclosureGroup(isExpanded: $showDownloads) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloads go to Hear Me Out's own folder. Nothing downloads unless you click.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
                    ForEach(library.downloadable, id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ModelNames.friendly(name)).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                if name == library.recommended { Text("Recommended for this Mac").font(.system(size: 10.5)).foregroundStyle(theme.palette.accent) }
                            }
                            Spacer()
                            if let p = library.downloading[name] {
                                ProgressView(value: p).frame(width: 120)
                                Text("\(Int(p * 100))%").font(.system(size: 11)).monospacedDigit()
                            } else if library.preparing.contains(name) {
                                ProgressView().controlSize(.small); Text("Preparing…").font(.system(size: 11))
                            } else if library.models.contains(where: { $0.name == name && $0.format.isCompatible }) {
                                StatusPill(text: "Installed", symbol: "checkmark", tone: .success)
                            } else {
                                Button("Download") { Task { await library.download(name) } }.buttonStyle(.pill(.secondary))
                            }
                        }
                    }
                    Text("Space used by Hear Me Out's own models: \(library.hearMeOutStorage.fileSizeText)")
                        .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
                }
                .padding(.top, 8)
                .task { await library.refreshDownloadable() }
            } label: {
                Text("Download a model instead").font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
    }

    private func originText(_ o: ModelOrigin) -> String {
        switch o {
        case .sharedFromLetsMeet: return "Shared from Let's Meet"
        case .hearMeOut: return "Installed for Hear Me Out"
        case .userFolder: return "From a folder you chose"
        case .huggingFaceCache: return "WhisperKit download cache"
        }
    }
}

// MARK: - Titles

struct TitleSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var target = ""
    @State private var openAIKey = ""
    @State private var models: [String] = []
    @State private var testing = false
    @State private var testResult: String?
    @State private var hasKey = OpenAITitleGenerator.apiKey != nil

    var body: some View {
        let account = model.account(target) ?? model.activeAccount
        let apple = AppleTitleGenerator.availability
        SettingsCard(title: "Who writes the titles", subtitle: "A title you type always wins and is never replaced.") {
            AccountTargetPicker(accountId: $target)
            ForEach(TitleProvider.allCases) { p in
                OptionCard(title: p.label, detail: p.explanation,
                           symbol: p == .appleIntelligence ? "sparkles" : p == .openAI ? "brain" : p == .hearMeOut ? "cloud.fill" : "pencil",
                           selected: account?.preferences.titleProvider == p,
                           badge: p == .appleIntelligence ? "On this Mac" : nil,
                           disabledReason: p == .appleIntelligence ? appleReason(apple) : (p == .openAI && !hasKey ? "Add your OpenAI key below first." : nil)) {
                    if let a = account { model.updateAccount(a.id) { $0.preferences.titleProvider = p } }
                }
            }
            if account?.preferences.transcription == TranscriptionMode.none {
                Text("This account doesn't make transcripts, so recordings are named by date unless you type a title.")
                    .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
            }
        }
        .onAppear { if target.isEmpty { target = model.activeAccountId ?? "" } }

        SettingsCard(title: "OpenAI", subtitle: "Only the transcript (at most ~6,000 characters) is sent, and only when OpenAI is chosen. Audio is never sent.") {
            if hasKey {
                HStack {
                    Label("API key saved in your Keychain", systemImage: "key.fill").font(.system(size: 12.5))
                    Spacer()
                    Button("Test connection") { Task { await test(key: nil) } }.buttonStyle(.pill(.secondary)).disabled(testing)
                    Button("Remove key", role: .destructive) {
                        Keychain.delete(Keychain.openAIAccount); hasKey = false; models = []; testResult = nil
                    }
                    .buttonStyle(.pill(.destructive))
                }
            } else {
                HStack {
                    SecureField("sk-…", text: $openAIKey).textFieldStyle(.roundedBorder)
                    Button("Save & test") { Task { await test(key: openAIKey) } }.buttonStyle(.pill(.primary)).disabled(openAIKey.isEmpty || testing)
                }
            }
            if testing { ProgressView().controlSize(.small) }
            if let r = testResult { Text(r).font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText) }
            if !models.isEmpty || hasKey {
                Picker("Model", selection: $model.settings.openAIModel) {
                    ForEach(Array(Set(models + [model.settings.openAIModel])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                Text("A small, inexpensive model is plenty for titles.").font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText)
            }
        }
    }

    private func appleReason(_ a: AppleTitleGenerator.Availability) -> String? {
        if case .unavailable(let why) = a { return why }
        return nil
    }

    private func test(key: String?) async {
        testing = true
        defer { testing = false }
        let k = key ?? OpenAITitleGenerator.apiKey ?? ""
        do {
            let list = try await OpenAITitleGenerator.test(key: k)
            if let key { try? Keychain.set(key, account: Keychain.openAIAccount); openAIKey = ""; hasKey = true }
            models = list
            if !list.contains(model.settings.openAIModel), let d = OpenAITitleGenerator.defaultModel(from: list) { model.settings.openAIModel = d }
            testResult = "Connected. \(list.count) models available."
        } catch {
            testResult = error.localizedDescription
        }
    }
}

// MARK: - Storage

struct StorageSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var audioBytes: Int64 = 0

    var body: some View {
        let items = model.engine.items
        let waiting = items.filter { !$0.cancelled && $0.upload != .ready }.count
        SettingsCard(title: "Processing queue", subtitle: "Work is saved to disk, so nothing recoverable is lost if Hear Me Out quits. Unfinished work resumes on the next launch.") {
            HStack(spacing: 10) {
                stat("\(model.engine.activeItems.count)", "In progress")
                stat("\(waiting)", "Waiting to upload")
                stat("\(items.filter(\.needsAttention).count)", "Need attention")
            }
            HStack {
                Button("Open Activity") { model.tab = .activity }.buttonStyle(.pill(.secondary))
                Button("Retry everything that failed") { for i in items where i.needsAttention { model.engine.retryNow(i.id) } }
                    .buttonStyle(.pill(.quiet))
            }
        }
        SettingsCard(title: "Audio on this Mac", subtitle: "A copy of each recording is kept until it's safely uploaded. Recordings that haven't uploaded are never removed.") {
            HStack {
                Text("Local audio: \(audioBytes.fileSizeText)").font(.system(size: 13))
                Spacer()
                Button("Remove uploaded audio now") {
                    let n = model.removeUploadedAudio()
                    audioBytes = model.localAudioBytes
                    model.showToast(n == 0 ? "Nothing to remove" : "Removed \(n) uploaded recording\(n == 1 ? "" : "s") from this Mac", symbol: "trash")
                }
                .buttonStyle(.pill(.secondary))
            }
            Picker("Remove uploaded audio automatically after", selection: $model.settings.removeUploadedAudioAfterDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Never").tag(0)
            }
            .frame(maxWidth: 420)
            Button("Show audio folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.audio]) }.buttonStyle(.pill(.quiet))
        }
        SettingsCard(title: "Sharing") {
            Toggle("Copy the link automatically when a recording is ready", isOn: $model.settings.copyLinkWhenReady).toggleStyle(.switch)
            Picker("Main share button", selection: $model.settings.preferredShareFormat) {
                ForEach(ShareFormat.allCases) { Text($0.action).tag($0) }
            }
            .frame(maxWidth: 360)
            Text("Hear Me Out never sends messages or emails for you.").font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
        }
        .onAppear { audioBytes = model.localAudioBytes }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(theme.titleFont(24))
            Text(label).font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.palette.surface))
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var serverOK: Bool?
    @State private var showDiagnostics = false

    var body: some View {
        SettingsCard(title: "Hear Me Out for Mac") {
            HStack(spacing: 14) {
                BrandMark(compact: true).scaleEffect(1.8).frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Version \(AppInfo.version) (\(AppInfo.build))").font(.system(size: 13, weight: .semibold))
                    Text("Native Apple Silicon app. No analytics, no tracking.").font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText)
                }
            }
            HStack(spacing: 8) {
                switch serverOK {
                case .some(true): StatusPill(text: "Hear Me Out is reachable", symbol: "checkmark", tone: .success)
                case .some(false): StatusPill(text: "Can't reach Hear Me Out", symbol: "wifi.exclamationmark", tone: .warning)
                case .none: StatusPill(text: "Checking connection…", tone: .neutral, spinning: true)
                }
                StatusPill(text: model.nativeSignInAvailable == true ? "Google sign-in enabled" : "Google sign-in not yet enabled on server",
                           symbol: "person.badge.key", tone: model.nativeSignInAvailable == true ? .success : .neutral)
            }
            HStack {
                Button("Open Hear Me Out") { NSWorkspace.shared.open(HMOClient.defaultOrigin) }.buttonStyle(.pill(.secondary))
                Button("Privacy") { NSWorkspace.shared.open(HMOClient.defaultOrigin.appendingPathComponent("privacy")) }.buttonStyle(.pill(.quiet))
                Button("Show onboarding again") { withAnimation { model.showOnboarding = true } }.buttonStyle(.pill(.quiet))
            }
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                Text(diagnostics).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }
        .task {
            var req = URLRequest(url: HMOClient.defaultOrigin)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 10
            serverOK = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
        }
    }

    private var diagnostics: String {
        let p = ProcessInfo.processInfo
        return """
        macOS \(p.operatingSystemVersionString)
        Accounts: \(model.accounts.count) (\(model.accounts.map { $0.authMethod.rawValue }.joined(separator: ", ")))
        Queue: \(model.engine.items.count) items, \(model.engine.activeItems.count) active
        Online: \(model.connectivity.isOnline)
        Whisper model: \(model.models.selectedModel?.name ?? "none")
        Apple Intelligence: \(AppleTitleGenerator.availability == .available ? "available" : "unavailable")
        Microphones: \(model.devices.devices.count)
        """
    }
}
