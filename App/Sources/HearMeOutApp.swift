import SwiftUI
import AppKit
import HearMeOutCore

@main
struct HearMeOutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let demo = ProcessInfo.processInfo.environment["HMO_DEMO"].flatMap(DemoScenario.init(rawValue:))
        let m = AppModel(demo: demo)
        if let look = ProcessInfo.processInfo.environment["HMO_APPEARANCE"] {
            m.settings.appearance = look == "dark" ? .dark : look == "light" ? .light : .themeDefault
        }
        _model = StateObject(wrappedValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window("Hear Me Out", id: "main") {
            RootView()
                .environmentObject(model)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 780)
        .commands { AppCommands(model: model) }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBar }, set: { model.settings.showMenuBar = $0 })) {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarIcon(recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar glyph: a waveform, or a red dot while recording.
struct MenuBarIcon: View {
    @ObservedObject var recorder: RecordingController
    var body: some View {
        switch recorder.state {
        case .recording: Image(systemName: "record.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.red, .primary)
        case .paused: Image(systemName: "pause.circle.fill")
        default: Image(systemName: "waveform")
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.recorder.isActive ? "Stop Recording" : "New Recording") { model.toggleRecording() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Import Audio…") { model.presentImportPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.tab = .settings }.keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Account") {
            ForEach(Array(model.accounts.prefix(9).enumerated()), id: \.element.id) { i, a in
                Button(a.title) { model.switchAccount(to: a.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
            }
            Divider()
            Button("Copy Most Recent Link") { model.copyLatestLink() }.keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["HMO_DEMO"] != nil {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opening audio files from Finder ("Open With → Hear Me Out" or dropping on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppDelegate.model?.bringToFront()
            AppDelegate.model?.importFiles(urls.filter { $0.isFileURL })
        }
    }

    /// Closing the window keeps Hear Me Out running in the menu bar so recording and uploads continue.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(AppDelegate.model?.settings.showMenuBar ?? true) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = AppDelegate.model, model.recorder.isActive else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "You're still recording"
            alert.informativeText = "Quitting now stops the recording. Stop it first to keep it."
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppDelegate.model?.bringToFront() } }
        return true
    }
}

/// Makes the window draggable by its background and records its frame for the screenshot workflow.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 860, height: 600)
            if let path = ProcessInfo.processInfo.environment["HMO_WINDOW_FRAME_FILE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let f = w.frame
                    let screen = w.screen ?? NSScreen.main
                    let sh = screen?.frame.height ?? 0
                    let sw = screen?.frame.width ?? 0
                    // Top-left origin for cropping a full-screen capture.
                    let json = "{\"x\":\(f.origin.x),\"y\":\(sh - f.origin.y - f.height),\"w\":\(f.width),\"h\":\(f.height),\"sw\":\(sw)}"
                    try? json.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
