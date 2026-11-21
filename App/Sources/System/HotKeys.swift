import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut (Carbon hot keys work in the sandbox and need no Accessibility permission).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X", UInt32(kVK_ANSI_Y): "Y",
            UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9", UInt32(kVK_Space): "Space", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        ]
        return map[code] ?? "Key \(code)"
    }

    /// Converts an NSEvent (from the shortcut recorder) into a Carbon shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        // Require at least two modifiers (or ⌘ plus one) to avoid clashing with ordinary typing.
        let count = [controlKey, optionKey, shiftKey, cmdKey].filter { m & UInt32($0) != 0 }.count
        guard count >= 2 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = m
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    static let defaultRecord = Shortcut(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | cmdKey)
    static let defaultOpen = Shortcut(keyCode: kVK_ANSI_H, modifiers: controlKey | optionKey | cmdKey)
    static let defaultCopyLink = Shortcut(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey | cmdKey)
}

enum HotKeyAction: UInt32, CaseIterable {
    case toggleRecording = 1, openApp = 2, copyLatestLink = 3

    var label: String {
        switch self {
        case .toggleRecording: return "Start or stop recording"
        case .openApp: return "Open Hear Me Out"
        case .copyLatestLink: return "Copy most recent link"
        }
    }
}

/// Registers app-wide shortcuts through Carbon's RegisterEventHotKey.
final class HotKeyCentre {
    static let shared = HotKeyCentre()
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    var handler: ((HotKeyAction) -> Void)?

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let action = HotKeyAction(rawValue: hk.id) {
                DispatchQueue.main.async { HotKeyCentre.shared.handler?(action) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers (or clears, with nil) the shortcut for an action. Returns false if macOS refused it (already in use).
    @discardableResult
    func register(_ action: HotKeyAction, _ shortcut: Shortcut?) -> Bool {
        installHandler()
        if let old = refs.removeValue(forKey: action) { UnregisterEventHotKey(old) }
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x484D4F21), id: action.rawValue)  // 'HMO!'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[action] = ref; return true }
        return false
    }
}
