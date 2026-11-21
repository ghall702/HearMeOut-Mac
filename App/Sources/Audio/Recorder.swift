import AVFoundation
import Combine
import HearMeOutCore

enum RecordingQuality: String, CaseIterable, Identifiable, Codable {
    case standard, high, studio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard · 96 kbps"
        case .high: return "High · 128 kbps"
        case .studio: return "Studio · 192 kbps"
        }
    }
    var bitRate: Int { self == .standard ? 96_000 : self == .high ? 128_000 : 192_000 }
}

/// A finished take, still on this Mac.
struct Take: Equatable {
    let url: URL
    /// The account selected when recording began. Changing accounts later never changes this.
    let accountId: String
    let recordedAt: Date
    let duration: Double
    let deviceName: String
    let note: String?
}

/// Live level meter values, kept separate so only the waveform and timer redraw 20× a second.
@MainActor
final class RecorderMeter: ObservableObject {
    @Published var level: Float = 0
    @Published var history: [Float] = Array(repeating: 0, count: 72)
    @Published var elapsed: TimeInterval = 0

    func push(_ v: Float) {
        level = v
        history.removeFirst()
        history.append(v)
    }

    func reset() {
        level = 0
        elapsed = 0
        history = Array(repeating: 0, count: history.count)
    }
}

/// Owns the microphone. Lives for the whole app session — not tied to any view — so recording
/// continues while you switch screens, apps or Spaces, until you stop it, the 15-minute cap is
/// reached, or the system interrupts the device.
@MainActor
final class RecordingController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case monitoring
        case starting
        case recording
        case paused
        case finished(Take)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    let meter = RecorderMeter()

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let sessionQueue = DispatchQueue(label: "hmo.recorder.session")
    private var currentInput: AVCaptureDeviceInput?
    private var meterTask: Task<Void, Never>?

    private var accountId = ""
    private var recordedAt = Date()
    private var deviceName = ""
    private var fileURL: URL?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var stopNote: String?
    private var discardOnFinish = false
    private var runtimeObserver: NSObjectProtocol?

    var onLimitReached: (() -> Void)?

    var isActive: Bool { state == .recording || state == .paused || state == .starting }
    var recordingAccountId: String? { isActive ? accountId : nil }

    override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] n in
            let message = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "The microphone stopped unexpectedly."
            Task { @MainActor in self?.handleRuntimeError(message) }
        }
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        if permission == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Session plumbing

    /// Reconfigures and starts the capture session off the main thread so the UI never stalls.
    private func configure(device: AVCaptureDevice, quality: RecordingQuality) async throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = self.output
        let session = self.session
        let old = currentInput
        let bitRate = quality.bitRate
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                session.beginConfiguration()
                if let old { session.removeInput(old) }
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    cont.resume(throwing: NSError(domain: "HMO", code: 1, userInfo: [NSLocalizedDescriptionKey: "This microphone can't be used right now."]))
                    return
                }
                session.addInput(input)
                if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: bitRate,
                ]
                output.maxRecordedDuration = CMTime(seconds: HMOLimits.maxRecordingSeconds, preferredTimescale: 600)
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                cont.resume()
            }
        }
        currentInput = input
    }

    private func stopSession() {
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let db = self.output.connections.first?.audioChannels.map(\.averagePowerLevel).max() ?? -160
                let norm = max(0, min(1, (db + 52) / 52))
                self.meter.push(self.state == .paused ? 0 : Float(pow(Double(norm), 1.6)))
                if self.state == .recording, let s = self.segmentStart {
                    self.meter.elapsed = self.accumulated + Date().timeIntervalSince(s)
                } else if self.state == .paused {
                    self.meter.elapsed = self.accumulated
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: Monitoring (mic test)

    /// Runs the microphone without recording so the picker can show live levels.
    func startMonitoring(device: AVCaptureDevice) {
        guard state == .idle || state == .monitoring else { return }
        state = .monitoring
        Task { @MainActor in
            do {
                try await configure(device: device, quality: .standard)
                if state == .monitoring { startMeter() } else if !isActive { stopSession() }
            } catch {
                if state == .monitoring { state = .idle }
            }
        }
    }

    func stopMonitoring() {
        guard state == .monitoring else { return }
        meterTask?.cancel()
        stopSession()
        meter.reset()
        state = .idle
    }

    // MARK: Recording

    func start(device: AVCaptureDevice, accountId: String, quality: RecordingQuality) async {
        guard !isActive else { return }
        guard await Self.requestPermission() else {
            state = .failed("Hear Me Out needs permission to use the microphone. Open System Settings → Privacy & Security → Microphone.")
            return
        }
        state = .starting
        // Captured the moment recording starts (handbook: recordedAt = when the audio was recorded).
        self.recordedAt = Date()
        self.accountId = accountId
        self.deviceName = device.localizedName
        self.accumulated = 0
        self.stopNote = nil
        self.discardOnFinish = false
        meter.reset()
        let url = AppPaths.audio.appendingPathComponent("\(UUID().uuidString).m4a")
        fileURL = url
        do {
            try await configure(device: device, quality: quality)
            output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            segmentStart = Date()
            state = .recording
            startMeter()
        } catch {
            state = .failed(error.localizedDescription)
            stopSession()
        }
    }

    func pause() {
        guard state == .recording else { return }
        output.pauseRecording()
        if let s = segmentStart { accumulated += Date().timeIntervalSince(s) }
        segmentStart = nil
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        output.resumeRecording()
        segmentStart = Date()
        state = .recording
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        if let s = segmentStart { accumulated += Date().timeIntervalSince(s) }
        segmentStart = nil
        output.stopRecording()   // delegate delivers the finished file
    }

    /// Stops and throws the audio away.
    func discardActive() {
        guard isActive else { return }
        discardOnFinish = true
        output.stopRecording()
    }

    /// Clears a finished take from the screen (after saving or discarding it).
    func reset(deleteFile: Bool) {
        if case .finished(let take) = state, deleteFile { try? FileManager.default.removeItem(at: take.url) }
        meter.reset()
        state = .idle
    }

    private func handleRuntimeError(_ message: String) {
        if state == .recording || state == .paused {
            stopNote = "The microphone was disconnected or interrupted, so recording stopped. Everything up to that point is kept."
            stop()
        } else if state == .monitoring {
            stopMonitoring()
        }
    }

    fileprivate func finish(url: URL, error: Error?) {
        meterTask?.cancel()
        stopSession()
        if discardOnFinish {
            try? FileManager.default.removeItem(at: url)
            discardOnFinish = false
            meter.reset()
            state = .idle
            return
        }
        var note = stopNote
        if let error = error as NSError? {
            let ok = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if error.code == AVError.maximumDurationReached.rawValue {
                note = "You reached the 15-minute limit, so recording stopped automatically."
                onLimitReached?()
            } else if !ok {
                state = .failed("Recording failed: \(error.localizedDescription)")
                return
            }
        }
        AppPaths.protect(url)
        let accountId = self.accountId, recordedAt = self.recordedAt, deviceName = self.deviceName
        let measured = accumulated
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            let d = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? measured
            let duration = d.isFinite && d > 0 ? min(d, HMOLimits.maxRecordingSeconds) : measured
            self.state = .finished(Take(url: url, accountId: accountId, recordedAt: recordedAt, duration: duration, deviceName: deviceName, note: note))
        }
    }
}

extension RecordingController {
    /// Screenshot/UI-test mode only: shows the recording state with synthetic levels, no microphone used.
    func demoSimulateRecording(accountId: String) {
        self.accountId = accountId
        state = .recording
        meter.elapsed = 83
        meter.history = (0..<meter.history.count).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.37)) * (0.6 + 0.4 * cos(Double(i) * 0.11))) }
        meter.level = 0.55
    }
}

extension RecordingController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.finish(url: outputFileURL, error: error) }
    }
}
