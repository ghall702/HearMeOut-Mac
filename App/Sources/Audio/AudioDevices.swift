import AVFoundation
import CoreAudio
import Combine

/// An input device. `id` is the Core Audio device UID, which AVCaptureDevice exposes as `uniqueID`.
struct InputDevice: Identifiable, Hashable {
    enum Kind { case builtIn, usb, bluetooth, interface, virtual, other }
    let id: String
    let name: String
    let kind: Kind
    let isSystemDefault: Bool

    var symbol: String {
        switch kind {
        case .builtIn: return "laptopcomputer"
        case .usb: return "mic.fill"
        case .bluetooth: return "headphones"
        case .interface: return "slider.vertical.3"
        case .virtual: return "waveform.circle"
        case .other: return "mic"
        }
    }

    var kindLabel: String {
        switch kind {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .interface: return "Audio interface"
        case .virtual: return "Virtual device"
        case .other: return "Microphone"
        }
    }
}

/// Lists microphones, follows hot-plugging and remembers the preferred device.
@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []
    @Published var preferredId: String? {
        didSet { UserDefaults.standard.set(preferredId, forKey: "preferredMicrophone") }
    }
    /// Set when the preferred device disappeared and we fell back to another one.
    @Published private(set) var fallbackNotice: String?

    private var observers: [NSObjectProtocol] = []

    init() {
        preferredId = UserDefaults.standard.string(forKey: "preferredMicrophone")
        refresh()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func refresh() {
        let defaultUID = Self.systemDefaultInputUID()
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        devices = session.devices.map { d in
            InputDevice(id: d.uniqueID, name: d.localizedName, kind: Self.kind(of: d), isSystemDefault: d.uniqueID == defaultUID)
        }
        .sorted { a, b in
            if a.isSystemDefault != b.isSystemDefault { return a.isSystemDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if let p = preferredId, !devices.contains(where: { $0.id == p }) {
            fallbackNotice = "Your chosen microphone isn't connected. Using \(current?.name ?? "the system default") instead."
        } else {
            fallbackNotice = nil
        }
    }

    /// The device recordings will use: the preferred one if connected, else the system default.
    var current: InputDevice? {
        if let p = preferredId, let d = devices.first(where: { $0.id == p }) { return d }
        return devices.first(where: { $0.isSystemDefault }) ?? devices.first
    }

    func captureDevice(for device: InputDevice?) -> AVCaptureDevice? {
        if let device, let d = AVCaptureDevice(uniqueID: device.id) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    static func kind(of d: AVCaptureDevice) -> InputDevice.Kind {
        let t = UInt32(bitPattern: d.transportType)
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return d.localizedName.localizedCaseInsensitiveContains("interface") ? .interface : .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI: return .interface
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }

    /// The system default input's UID, read from Core Audio.
    static func systemDefaultInputUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }
}
