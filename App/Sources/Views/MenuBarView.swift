import SwiftUI
import HearMeOutCore

/// Compact menu bar panel in the same design language as the main window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let resolved = model.resolvedTheme()
        MenuBarContent(openMain: { openMain() })
            .environment(\.hmoTheme, resolved)
            .preferredColorScheme(resolved.scheme)
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hmoTheme) private var theme
    let openMain: () -> Void

    var body: some View {
        let state = model.recorder.state
        let active = state == .recording || state == .paused
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BrandMark()
                Spacer()
                Menu {
                    ForEach(model.accounts) { a in
                        Button { model.switchAccount(to: a.id) } label: {
                            Text(a.title + (a.id == model.activeAccountId ? "  ✓" : ""))
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        AvatarView(account: model.activeAccount, size: 20)
                        Text(model.activeAccount?.title ?? "No account").font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(active)
            }
            HStack(spacing: 14) {
                Button { model.toggleRecording() } label: {
                    Image(systemName: active ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(active ? theme.palette.record : theme.palette.accent))
                        .shadow(color: (active ? theme.palette.record : theme.palette.accent).opacity(0.4), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(active ? "Stop recording" : "Start recording")
                VStack(alignment: .leading, spacing: 4) {
                    MenuTimer(meter: model.recorder.meter, active: active)
                    Text(active ? "Recording to \(model.account(model.recorder.recordingAccountId)?.title ?? "")" : "Ready · \(model.devices.current?.name ?? "No microphone")")
                        .font(.system(size: 11)).foregroundStyle(theme.palette.secondaryText).lineLimit(1)
                }
            }
            if active {
                LiveWaveform(meter: model.recorder.meter, active: true).frame(height: 34)
            }
            if case .finished = state {
                Button { openMain() } label: { Label("Review and save your recording", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(.pill(.primary))
            }
            Divider().opacity(0.4)
            if let latest = model.latestShareable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Most recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.palette.secondaryText)
                    Text(latest.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    HStack {
                        Button { model.copy(.link, links: latest.links) } label: { Label("Copy link", systemImage: "link") }.buttonStyle(.pill(.secondary))
                        Button { model.copy(.gmail, links: latest.links) } label: { Label("Gmail", systemImage: "envelope") }.buttonStyle(.pill(.quiet))
                    }
                }
            }
            let running = model.engine.activeItems.count
            if running > 0 {
                Label("\(running) processing in the background", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5)).foregroundStyle(theme.palette.secondaryText)
            }
            HStack {
                Button("Open Hear Me Out") { openMain() }.buttonStyle(.pill(.quiet))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.pill(.quiet))
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(ThemeBackdrop(showMotif: false))
    }
}

struct MenuTimer: View {
    @ObservedObject var meter: RecorderMeter
    let active: Bool
    @Environment(\.hmoTheme) private var theme
    var body: some View {
        Text(active ? meter.elapsed.clockText : "Record a voice note")
            .font(.system(size: active ? 22 : 15, weight: active ? .light : .semibold, design: .rounded)).monospacedDigit()
    }
}
