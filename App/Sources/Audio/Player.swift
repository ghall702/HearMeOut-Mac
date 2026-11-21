import AVFoundation
import Combine

/// Reads a short list of loudness peaks from an audio file for drawing a waveform (off the main thread).
enum WaveformReader {
    static func peaks(url: URL, count: Int = 90) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let total = file.length
            guard total > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                                                         channels: 1, interleaved: false) else { return [] }
            let perBin = max(1, Int(total) / count)
            let chunk = AVAudioFrameCount(min(perBin, 1 << 16))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
            _ = format
            var out: [Float] = []
            out.reserveCapacity(count)
            for bin in 0..<count {
                file.framePosition = AVAudioFramePosition(bin * perBin)
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                guard let data = buffer.floatChannelData?[0] else { break }
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                var sum: Float = 0
                var i = 0
                while i < n { sum += data[i] * data[i]; i += 4 }
                out.append(sqrt(sum / Float(max(1, n / 4))))
            }
            let peak = out.max() ?? 1
            return peak > 0 ? out.map { min(1, $0 / peak) } : out
        }.value
    }
}

/// A small AVPlayer wrapper with time, seeking and speed for the review card and library.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var peaks: [Float] = []
    @Published private(set) var url: URL?
    @Published var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }
    @Published private(set) var isLoading = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(_ url: URL, knownDuration: Double? = nil, readPeaks: Bool) {
        guard url != self.url else { return }
        stop()
        self.url = url
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        player = p
        duration = knownDuration ?? 0
        currentTime = 0
        peaks = []
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = CMTimeGetSeconds(t)
                if let d = self.player?.currentItem?.duration, d.isNumeric, CMTimeGetSeconds(d) > 0 { self.duration = CMTimeGetSeconds(d) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
                self?.currentTime = 0
            }
        }
        if readPeaks && url.isFileURL {
            isLoading = true
            Task { @MainActor in
                let p = await WaveformReader.peaks(url: url)
                if self.url == url { self.peaks = p; self.isLoading = false }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false } else { player.playImmediately(atRate: rate); isPlaying = true }
    }

    func seek(fraction: Double) {
        guard let player, duration > 0 else { return }
        let t = max(0, min(duration, duration * fraction))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) {
        guard duration > 0 else { return }
        seek(fraction: (currentTime + seconds) / duration)
    }

    func stop() {
        player?.pause()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        url = nil
    }

    var progress: Double { duration > 0 ? currentTime / duration : 0 }
}
