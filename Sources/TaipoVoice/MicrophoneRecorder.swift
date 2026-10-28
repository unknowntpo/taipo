@preconcurrency import AVFoundation
import os
import TaipoIME

private let log = Logger(subsystem: "com.unknowntpo.inputmethod.Taipo", category: "voice")

/// Spec 012 Behavior 2: records the default input as 16 kHz mono Float32 into memory.
/// Audio is never written to disk.
public final class MicrophoneRecorder: VoiceRecorder, @unchecked Sendable {
    public enum Failure: LocalizedError {
        case permissionDenied
        case permissionRequested
        case noInput
        case unsupportedFormat

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: "麥克風權限被拒，請到系統設定 > 隱私權與安全性 > 麥克風開啟 Taipo"
            case .permissionRequested: "請允許麥克風權限後再試一次"
            case .noInput: "沒有可用的麥克風"
            case .unsupportedFormat: "麥克風格式無法轉換"
            }
        }
    }

    public static let sampleRate = 16_000.0
    /// A little above the 60 s cap so the state machine's own timer decides.
    static let maximumSamples = Int(sampleRate * 61)

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false
    private var throttle = LevelThrottle()
    private var spectrum = VoiceSpectrum()
    private var levelHandler: (@Sendable ([Float]) -> Void)?

    public init() {}

    /// Called on the audio thread with the band levels (0…1) of the latest 512-sample frame,
    /// at most 30 times a second (W13). The first call is also the first real microphone audio (W16).
    public var onLevels: (@Sendable ([Float]) -> Void)? {
        get { lock.withLock { levelHandler } }
        set { lock.withLock { levelHandler = newValue } }
    }

    public func start() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw Failure.permissionRequested
        default:
            throw Failure.permissionDenied
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure.unsupportedFormat }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            throttle = LevelThrottle()
            spectrum = VoiceSpectrum()
        }
        let target = target
        // A smaller buffer gives the waveform more updates; the system may still deliver larger ones.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
        log.notice("recording started, input \(Int(format.sampleRate), privacy: .public) Hz \(format.channelCount, privacy: .public) ch")
    }

    public func stop() -> [Float] {
        halt()
        let recorded = lock.withLock {
            defer { samples = [] }
            return samples
        }
        log.notice("recording stopped, \(recorded.count, privacy: .public) samples")
        return recorded
    }

    public func cancel() {
        halt()
        lock.withLock { samples = [] }
        log.notice("recording cancelled")
    }

    private func halt() {
        guard running else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        // The input block runs synchronously inside convert(); it hands over this one buffer.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let buffer = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let frames = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        let update: (handler: @Sendable ([Float]) -> Void, levels: [Float])? = lock.withLock {
            let room = Self.maximumSamples - samples.count
            if room > 0 { samples.append(contentsOf: frames.prefix(room)) }
            guard let levels = spectrum.feed(Array(frames)), let levelHandler,
                  throttle.allow(at: ProcessInfo.processInfo.systemUptime) else { return nil }
            return (levelHandler, levels)
        }
        if let update { update.handler(update.levels) }
    }
}
