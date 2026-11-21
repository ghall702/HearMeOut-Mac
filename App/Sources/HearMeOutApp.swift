import SwiftUI
import AppKit
import Combine
import HearMeOutCore

@main
struct HearMeOutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let demo = ProcessInfo.processInfo.environment["HMO_DEMO"].flatMap(DemoScenario.init(rawValue:))
        if demo != nil { AppDelegate.log("app init start") }
        let m = AppModel.shared(demo: demo)
        if demo != nil { AppDelegate.log("model ready") }
        if let look = ProcessInfo.processInfo.environment["HMO_APPEARANCE"], demo != nil {
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
        let env = ProcessInfo.processInfo.environment
        guard env["HMO_DEMO"] != nil else { return }
        Self.log("did finish launching")
        if let model = AppDelegate.model {
            let counter = ChangeCounter()
            counter.cancellable = model.objectWillChange.sink { _ in counter.increment() }
            Self.counter = counter
            DispatchQueue.global().async {
                for second in 1...12 {
                    Thread.sleep(forTimeInterval: 1)
                    Self.log("t+\(second)s model changes: \(counter.take())")
                }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let name = env["HMO_SNAPSHOT_NAME"] else { return }
        // Screenshot mode: find the main window, size it, render it to PNG, quit.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            Self.log("windows: \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible) frame=\($0.frame)" })")
            if Self.mainWindow() == nil { AppDelegate.model?.openMainWindow?() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let w = Self.mainWindow() {
                w.setContentSize(NSSize(width: 1180, height: 800))
                w.center()
                w.makeKeyAndOrderFront(nil)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let w = Self.mainWindow() {
                WindowConfigurator.snapshot(w, name: name)
            } else {
                Self.log("no main window found")
            }
            exit(0)
        }
    }

    static var counter: ChangeCounter?

    @MainActor
    static func mainWindow() -> NSWindow? {
        NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 500 && !$0.className.contains("StatusBar") }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    nonisolated static func log(_ s: String) {
        FileHandle.standardError.write(Data("HMO: \(s)\n".utf8))
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
            guard let model = AppDelegate.model, model.recorder.isActive, !model.isDemo else { return .terminateNow }
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

/// Makes the window draggable by its background. In demo mode it can also snapshot its own window
/// (HMO_SNAPSHOT_NAME) for the CI screenshot review — no screen-recording permission needed.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 860, height: 600)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func snapshot(_ window: NSWindow, name: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { AppDelegate.log("no view to snapshot"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        do { try data.write(to: url); AppDelegate.log("snapshot \(url.path) \(data.count) bytes") }
        catch { AppDelegate.log("snapshot write failed: \(error.localizedDescription)") }
    }
}

/// Counts change notifications (screenshot diagnostics only).
final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var cancellable: AnyCancellable?
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func take() -> Int { lock.lock(); defer { count = 0; lock.unlock() }; return count }
}
