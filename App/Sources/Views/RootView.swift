import SwiftUI
import UniformTypeIdentifiers
import HearMeOutCore

/// The main window: a full-bleed themed backdrop with a floating top bar — no utility sidebar.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    var body: some View {
        let resolved = model.resolvedTheme()
        ZStack {
            ThemeBackdrop(showMotif: model.settings.decorations)
                .id(resolved.theme.id + (resolved.scheme == .dark ? "-d" : "-l"))
                .transition(.opacity)

            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    TopBar()
                    ZStack {
                        switch model.tab {
                        case .create: CreateView().transition(.opacity)
                        case .library: LibraryView().transition(.opacity)
                        case .activity: ActivityView().transition(.opacity)
                        case .settings: SettingsView().transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.tab)
                }
                if let preview = model.previewThemeId {
                    VStack { Spacer(); ThemePreviewBanner(themeId: preview).padding(.bottom, 22) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if dropTargeted { DropOverlay().transition(.opacity) }

            VStack {
                if let toast = model.toast {
                    ToastView(toast: toast).padding(.top, 64).transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .environment(\.hmoTheme, resolved)
        .preferredColorScheme(model.settings.appearance == .system ? nil : resolved.scheme)
        .tint(resolved.palette.accent)
        .foregroundStyle(resolved.palette.text)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: resolved.theme.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: resolved.scheme)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted.animation(.easeOut(duration: 0.15))) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .onAppear { model.systemScheme = systemScheme }
        .onChange(of: systemScheme) { _, s in model.systemScheme = s }
        .sheet(isPresented: $model.showImportSheet) { ImportSheet().environment(\.hmoTheme, resolved).environmentObject(model) }
        .frame(minWidth: 860, minHeight: 600)
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.importFiles(urls) }
    }
}

struct DropOverlay: View {
    @Environment(\.hmoTheme) private var theme
    var body: some View {
        ZStack {
            theme.palette.backgroundTop.opacity(0.75)
            VStack(spacing: 14) {
                Image(systemName: "waveform.badge.plus").font(.system(size: 54, weight: .light)).foregroundStyle(theme.palette.accent)
                Text("Drop audio to import").font(theme.titleFont(26)).foregroundStyle(theme.palette.text)
                Text("M4A, MP3, WAV, FLAC, AAC, OGG, Opus or WebM · up to 15 minutes")
                    .font(.system(size: 13)).foregroundStyle(theme.palette.secondaryText)
            }
            .padding(48)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(theme.palette.accent, style: StrokeStyle(lineWidth: 2, dash: [9, 7])))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @Namespace private var navSpace

    var body: some View {
        HStack(spacing: 14) {
            // Space for the window's traffic lights.
            Color.clear.frame(width: 64, height: 1)
            BrandMark()
            Spacer(minLength: 12)
            nav
            Spacer(minLength: 12)
            AccountChip()
            IconButton(symbol: "gearshape", size: 32, help: "Settings") { model.tab = .settings }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(height: 58)
    }

    private var nav: some View {
        HStack(spacing: 2) {
            ForEach([AppTab.create, .library, .activity]) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.tab = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 11.5, weight: .semibold))
                        Text(tab.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                        if tab == .activity, model.engine.activeItems.count > 0 {
                            Text("\(model.engine.activeItems.count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(selected ? theme.palette.onAccent.opacity(0.25) : theme.palette.accentSoft))
                        }
                    }
                    .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.text.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule().fill(theme.palette.accent).matchedGeometryEffect(id: "nav", in: navSpace)
                                .shadow(color: theme.palette.accent.opacity(0.35), radius: 8, y: 3)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(tab == .create ? 1 : tab == .library ? 2 : 3))), modifiers: .command)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().fill(theme.palette.surface))
        .overlay(Capsule().strokeBorder(theme.palette.stroke))
    }
}

struct BrandMark: View {
    @Environment(\.hmoTheme) private var theme
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: theme.palette.wave, startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 2) {
                    ForEach([0.45, 0.85, 0.6, 1.0, 0.5], id: \.self) { h in
                        Capsule().fill(.white).frame(width: 2.2, height: 13 * h)
                    }
                }
            }
            .frame(width: 26, height: 26)
            if !compact {
                Text("Hear Me Out").font(theme.titleFont(16, weight: .bold)).foregroundStyle(theme.palette.text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hear Me Out")
    }
}

// MARK: - Account chip & switcher

struct AccountChip: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { model.showAccountSwitcher.toggle() } label: {
            HStack(spacing: 8) {
                AvatarView(account: model.activeAccount, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeAccount?.title ?? "No account")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    if let e = model.activeAccount?.email, e != model.activeAccount?.title {
                        Text(e).font(.system(size: 10.5)).foregroundStyle(theme.palette.secondaryText).lineLimit(1)
                    }
                }
                .frame(maxWidth: 170, alignment: .leading)
                if model.activeAccount?.needsReconnect == true {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(theme.palette.warning)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.palette.secondaryText)
            }
            .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
            .background(Capsule().fill(hovering ? theme.palette.surfaceStrong : theme.palette.surface))
            .overlay(Capsule().strokeBorder(theme.palette.stroke))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $model.showAccountSwitcher, arrowEdge: .bottom) {
            AccountSwitcher().environment(\.hmoTheme, model.resolvedTheme()).environmentObject(model)
        }
        .help("Switch account (⌘⇧A)")
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .accessibilityLabel("Account: \(model.activeAccount?.title ?? "none"). Switch account.")
    }
}

struct AccountSwitcher: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts").font(theme.titleFont(17)).padding(.horizontal, 6)
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                AccountRow(account: account, active: account.id == model.activeAccountId, shortcut: index + 1) {
                    model.switchAccount(to: account.id)
                    model.showAccountSwitcher = false
                }
            }
            if model.accounts.isEmpty {
                Text("No accounts connected yet.").font(.system(size: 13)).foregroundStyle(theme.palette.secondaryText).padding(6)
            }
            Divider().opacity(0.4)
            HStack {
                Button { model.showAccountSwitcher = false; model.tab = .settings; model.settingsSection = .accounts } label: {
                    Label("Add account", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.pill(.secondary))
                Spacer()
                Button("Manage…") { model.showAccountSwitcher = false; model.tab = .settings; model.settingsSection = .accounts }
                    .buttonStyle(.pill(.quiet))
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(ThemeBackdrop(showMotif: false))
    }
}

struct AccountRow: View {
    @Environment(\.hmoTheme) private var theme
    let account: Account
    let active: Bool
    var shortcut: Int? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let t = ThemeCatalog.theme(account.themeId)
        let p = t.palette(t.preferred)
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(account: account, size: 38, ring: active)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundStyle(theme.palette.text)
                    Text(account.email ?? (account.authMethod == .apiKey ? "Connected with an API key" : ""))
                        .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(LinearGradient(colors: [p.backgroundTop, p.accent], startPoint: .top, endPoint: .bottom)).frame(width: 9, height: 9)
                        Text(t.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.palette.secondaryText)
                        if account.needsReconnect { StatusPill(text: "Reconnect", symbol: "exclamationmark", tone: .warning) }
                    }
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.palette.accent).font(.system(size: 17))
                } else if let shortcut, shortcut <= 9 {
                    Text("⌃\(shortcut)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(theme.palette.secondaryText)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? theme.palette.accentSoft : (hovering ? theme.palette.surfaceStrong : theme.palette.surface)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(account.title)\(active ? ", current account" : "")")
    }
}

struct ThemePreviewBanner: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let themeId: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: ThemeCatalog.theme(themeId).symbol).foregroundStyle(theme.palette.accent)
            Text("Previewing \(ThemeCatalog.theme(themeId).name)").font(.system(size: 13, weight: .semibold, design: .rounded))
            Button("Cancel") { withAnimation { model.previewThemeId = nil } }.buttonStyle(.pill(.secondary))
            Button(model.settings.useGlobalTheme ? "Use everywhere" : "Use for \(model.activeAccount?.title ?? "this account")") { model.applyTheme(themeId) }
                .buttonStyle(.pill(.primary))
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(theme.palette.stroke))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }
}
