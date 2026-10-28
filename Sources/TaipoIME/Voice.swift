import Accelerate
import Foundation

// Spec 012: voice input. Everything here is pure logic; the microphone, the recognizer, timers
// and the client are injected so the hold / release state machine is unit-tested with fakes.

/// The "語音輸入" switch and model location, shared by the IME and the Taipo app.
public enum VoiceSettings {
    public static let enabledKey = "voiceInputEnabled"
    /// Posted (distributed) by the Taipo app when the switch changes or the model is downloaded.
    public static let changed = Notification.Name("com.unknowntpo.inputmethod.Taipo.voiceSettingsChanged")

    /// Breeze-ASR-25 GGML q5_0 (W4 decision), pinned to one Hugging Face revision.
    public static let modelFileName = "ggml-breeze-asr-25-q5_0.bin"
    public static let modelDownloadURL = URL(string:
        "https://huggingface.co/shdennlin/breeze-asr-25-ggml/resolve/36c726093efe1760d1dd39c3cfe8b6a7282437d1/ggml-breeze-asr-25-q5_0.bin")!
    public static let modelSHA256 = "f51573bd6ef9b1fac0bd09a1652eda58a1a638d824a08771ccdee1102fe5990a"
    public static let modelBytes: Int64 = 1_080_732_091

    public static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Taipo/models")
    }
    public static var modelURL: URL { modelDirectory.appendingPathComponent(modelFileName) }

    public static func isEnabled(in defaults: UserDefaults? = DecisionSettings.sharedDefaults) -> Bool {
        defaults?.bool(forKey: enabledKey) ?? false
    }

    public static func setEnabled(_ value: Bool, in defaults: UserDefaults? = DecisionSettings.sharedDefaults) {
        defaults?.set(value, forKey: enabledKey)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, deliverImmediately: true)
    }

    public static func isModelInstalled(at url: URL = modelURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// W3: right Shift is only intercepted when the switch is on and the model is installed.
    public static func isAvailable(defaults: UserDefaults? = DecisionSettings.sharedDefaults, modelURL: URL = modelURL) -> Bool {
        isEnabled(in: defaults) && isModelInstalled(at: modelURL)
    }
}

/// Behavior 4: trim the ends and delete standalone fillers 嗯 / 呃 / 欸. A filler is standalone when
/// it forms a whole word between separators (start, end, whitespace or punctuation); "嗯哼" or
/// "欸你好" are kept. The separator before the filler goes with it, or the one after at the start.
public enum FillerFilter {
    public static let fillers: Set<Character> = ["嗯", "呃", "欸"]

    public static func clean(_ text: String) -> String {
        var runs: [(text: String, isSeparator: Bool)] = []
        for c in text {
            let sep = isSeparator(c)
            if let last = runs.last, last.isSeparator == sep { runs[runs.count - 1].text.append(c) }
            else { runs.append((String(c), sep)) }
        }
        var i = 0
        while i < runs.count {
            let run = runs[i]
            guard !run.isSeparator, run.text.allSatisfy(fillers.contains) else { i += 1; continue }
            if i > 0 {
                runs.removeSubrange((i - 1)...i)  // the separator before goes with the filler
                i -= 1
            } else {
                runs.removeSubrange(0...min(1, runs.count - 1))
            }
        }
        let joined = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.contains(where: { !isSeparator($0) }) ? joined : ""
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c.isPunctuation || c.isSymbol
    }
}

/// What voice input sees of the keyboard.
public enum VoiceEvent: Equatable, Sendable { case triggerDown, triggerUp, escape, otherKey }

/// Behavior 1: the trigger is right Shift (keyCode 60) pressed alone, seen as `flagsChanged`.
/// 2026-10-26: was right Command, which did nothing on the user's Mac (cause not investigated).
public enum RightShift {
    public static let keyCode: UInt16 = 60
    /// Device-independent bits of NSEvent.ModifierFlags. The left/right device bits are not
    /// used: they were absent from the events the IME received (2026-10-26, right ⌘ and the
    /// left-⇧ toggle both never fired), so the side comes from the keyCode alone.
    static let shift: UInt = 1 << 17
    static let control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20, function: UInt = 1 << 23

    /// Maps one `flagsChanged` event. Any other modifier change is `.otherKey`, so a shortcut
    /// held from right Shift discards the recording. A capital letter typed with right Shift is
    /// a keyDown while armed, which also resets and passes the key on (W1).
    public static func event(keyCode: UInt16, flags: UInt) -> VoiceEvent {
        guard keyCode == Self.keyCode else { return .otherKey }
        guard flags & shift != 0 else { return .triggerUp }
        return flags & (control | option | command | function) == 0 ? .triggerDown : .otherKey
    }
}

/// Records 16 kHz mono Float32 into memory (Behavior 2). Never writes audio to disk.
public protocol VoiceRecorder: AnyObject {
    func start() throws
    /// Stops and returns the samples recorded since `start`.
    func stop() -> [Float]
    /// Stops and discards.
    func cancel()
}

/// Turns 16 kHz mono samples into text (Behavior 3). Must honour task cancellation.
public protocol SpeechRecognizer: AnyObject, Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// What the floating bar shows (Behavior 8). The composition area is never used for voice status.
public enum VoiceBar: Equatable, Sendable {
    case hidden
    /// Recording, but no microphone levels yet (W16): muted bars with a travelling pulse.
    case arming
    /// Recording; one smoothed level per band, 0…1 (see `VoiceSpectrum`, `LevelSmoother`).
    case listening(levels: [Float])
    case recognizing
    /// One line, shown for `VoiceSession.errorDuration`.
    case error(String)
}

/// W13: the bar's band levels from 16 kHz microphone samples. Each 512-sample frame (32 ms) gets
/// its mean removed and a Hann window, then a real DFT (vDSP). The bins between 400 and 4000 Hz,
/// where speech is, are grouped into 9 bands that widen with frequency. A band's mean power in dB
/// maps from `floorDB` (0) to `ceilingDB` (1), then ×`gain` and ^`curve`, clamped; each inner band
/// then blends 15% of each neighbour. The approach and constants follow Handy's audio visualizer
/// (MIT, github.com/cjpais/Handy), reimplemented here.
public struct VoiceSpectrum {
    public static let bandCount = 9, windowSize = 512
    public static let sampleRate = 16_000.0
    public static let lowHz = 400.0, highHz = 4000.0
    /// The dB scale is per-bin power relative to the window size, not dBFS: speech lands around
    /// -32, a quiet room around -48.
    public static let floorDB: Float = -68, ceilingDB: Float = -30, gain: Float = 1.3, curve: Float = 0.7

    /// The DFT bins of each band; band b spans lowHz + (highHz - lowHz) × (b / 9)² up to (b + 1).
    public static let bins: [Range<Int>] = (0..<bandCount).map { b in
        func bin(_ fraction: Double) -> Int {
            let hz = lowHz + (highHz - lowHz) * fraction * fraction
            return min(windowSize / 2, Int(hz * Double(windowSize) / sampleRate))
        }
        let start = bin(Double(b) / Double(bandCount))
        return start..<max(start + 1, bin(Double(b + 1) / Double(bandCount)))
    }

    private static let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                            count: windowSize, isHalfWindow: false)
    /// Shared and never destroyed; vDSP DFT setups are safe to use from several threads.
    nonisolated(unsafe) private static let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(windowSize), .FORWARD)!
    private var pending: [Float] = []

    public init() {}

    /// Adds samples; returns band levels each time a full window has arrived, else nil. The
    /// newest `windowSize` samples are used and the rest dropped, so the bars stay current.
    public mutating func feed(_ samples: [Float]) -> [Float]? {
        pending.append(contentsOf: samples)
        guard pending.count >= Self.windowSize else { return nil }
        let frame = Array(pending.suffix(Self.windowSize))
        pending.removeAll(keepingCapacity: true)
        return Self.blend(levels(of: frame))
    }

    private func levels(of frame: [Float]) -> [Float] {
        let centered = vDSP.add(-vDSP.mean(frame), frame)
        let windowed = vDSP.multiply(centered, Self.window)
        // complexReal takes the even samples as the real part and the odd ones as the imaginary.
        let even = stride(from: 0, to: Self.windowSize, by: 2).map { windowed[$0] }
        let odd = stride(from: 1, to: Self.windowSize, by: 2).map { windowed[$0] }
        var re = [Float](repeating: 0, count: Self.windowSize / 2), im = re
        vDSP_DFT_Execute(Self.setup, even, odd, &re, &im)
        // vDSP's real DFT is 2× the textbook DFT; im[0] holds Nyquist, not part of any band.
        let n = Float(Self.windowSize)
        return Self.bins.map { range in
            var power: Float = 0
            for k in range where k < Self.windowSize / 2 {
                let x = re[k] / 2, y = k == 0 ? 0 : im[k] / 2
                power += x * x + y * y
            }
            let mean = power / Float(range.count)
            let db: Float = mean > 1e-12 ? 10 * log10(mean) - 20 * log10(n) : -80
            return Self.level(db: db)
        }
    }

    /// The dB → 0…1 mapping.
    public static func level(db: Float) -> Float {
        let normalized = min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
        return min(1, max(0, pow(normalized * gain, curve)))
    }

    /// Each inner band keeps 70% and takes 15% from each neighbour (from the unblended values).
    public static func blend(_ levels: [Float]) -> [Float] {
        guard levels.count > 2 else { return levels }
        var out = levels
        for i in 1..<(levels.count - 1) { out[i] = 0.7 * levels[i] + 0.15 * (levels[i - 1] + levels[i + 1]) }
        return out
    }
}

/// W17: per-band exponential smoothing for the bars, previous × 0.7 + new × 0.3, from 0.
public struct LevelSmoother: Sendable {
    public static let keep: Float = 0.7
    private var levels: [Float] = []

    public init() {}

    public mutating func smooth(_ new: [Float]) -> [Float] {
        if levels.count != new.count { levels = Array(repeating: 0, count: new.count) }
        levels = zip(levels, new).map { Self.keep * $0 + (1 - Self.keep) * $1 }
        return levels
    }
}

/// W18, W25: the bar's visibility. Every show and hide takes a new generation; a finished
/// fade-out orders the panel out only if nothing came after its hide, so a new session is never
/// hidden by an old fade. A show fades in whenever the bar is not fully on screen, and a fade-out
/// that ends after a show restores the bar, so no order of shows and hides leaves it transparent.
public struct BarFade: Sendable {
    /// What a show does to the panel.
    public enum Show: Sendable, Equatable {
        /// Order the panel in and fade it to fully opaque.
        case fadeIn
        /// The bar is already on screen and opaque; only its content or width changes.
        case keep
    }

    /// What the panel does when a fade-out ends.
    public enum FadeOutEnd: Sendable, Equatable {
        /// No show came after this hide: order the panel out.
        case orderOut
        /// A show came after this hide: make sure the panel is on screen and opaque.
        case restore
        /// A later hide owns the panel.
        case ignore
    }

    private var generation = 0
    public private(set) var isShown = false

    public init() {}

    /// `visible` and `opaque` describe the panel now; a bar marked shown but not on screen is shown again.
    @discardableResult public mutating func show(visible: Bool = false, opaque: Bool = false) -> Show {
        if isShown && visible && opaque { return .keep }
        isShown = true
        generation += 1
        return .fadeIn
    }

    /// Returns the token the fade-out passes to `fadeOutEnded`, or nil when the bar is already hidden.
    public mutating func hide() -> Int? {
        guard isShown else { return nil }
        isShown = false
        generation += 1
        return generation
    }

    public func fadeOutEnded(_ hide: Int) -> FadeOutEnd {
        if hide == generation { return .orderOut }
        return isShown ? .restore : .ignore
    }
}

/// W13: lets at most one level update through per `interval` (30 per second).
public struct LevelThrottle: Sendable {
    public static let interval = 1.0 / 30
    private var last: Double?

    public init() {}

    public mutating func allow(at time: Double) -> Bool {
        if let last, time - last < Self.interval { return false }
        last = time
        return true
    }
}

/// The input client as voice input sees it.
@MainActor public protocol VoiceHost: AnyObject {
    /// Sends the current composition, if any (Behavior 1: composing, then right Shift).
    func commitComposition()
    /// Shows, updates or hides the floating bar (Behavior 8).
    func showVoiceBar(_ bar: VoiceBar)
    /// Inserts recognized text at the cursor (Behavior 5).
    func insertVoiceText(_ text: String)
}

/// One finished voice input, for the live inspector (W10).
public struct VoiceReport: Sendable, Equatable {
    public let audioSeconds: Double
    public let recognitionSeconds: Double
    public let text: String?
    public let error: String?
}

/// The hold / release state machine (Spec 012 Behavior 1, 2, 5, 7).
@MainActor public final class VoiceSession {
    public enum State: Equatable, Sendable { case idle, armed, recording, recognizing }

    public static let minimumHold = 0.3
    public static let maximumRecording = 60.0
    public static let recognitionTimeout = 10.0
    public static let errorDuration = 2.0
    static let sampleRate = 16_000.0

    public private(set) var state = State.idle
    public weak var host: VoiceHost?
    public var onReport: ((VoiceReport) -> Void)?

    private let recorder: VoiceRecorder
    private let recognizer: SpeechRecognizer
    private let isAvailable: () -> Bool
    private let schedule: (Double, @escaping @MainActor () -> Void) -> Void
    private let now: () -> Double
    /// Bumped on every transition out of a timed state, so stale timers and late results are ignored.
    private var generation = 0
    private var showsError = false
    private var smoother = LevelSmoother()
    /// Recording was started by a tap and runs until the next tap (W20).
    private var handsFree = false
    /// In hands-free recording, right Shift is down again; its release stops (W21).
    private var stopPending = false
    private var task: Task<Void, Never>?

    public init(recorder: VoiceRecorder, recognizer: SpeechRecognizer, isAvailable: @escaping () -> Bool,
                schedule: @escaping (Double, @escaping @MainActor () -> Void) -> Void, now: @escaping () -> Double) {
        self.recorder = recorder
        self.recognizer = recognizer
        self.isAvailable = isAvailable
        self.schedule = schedule
        self.now = now
    }

    /// Returns true when voice input took the event. For a keyDown that means the app must not
    /// receive it; for right Shift it means voice input acted (W3).
    @discardableResult public func handle(_ event: VoiceEvent) -> Bool {
        switch (state, event) {
        case (.idle, .triggerDown):
            guard isAvailable() else { return false }
            clearError()
            state = .armed
            generation += 1
            let armed = generation
            schedule(Self.minimumHold) { [weak self] in
                guard let self, self.state == .armed, self.generation == armed else { return }
                self.beginRecording()
            }
            return true
        case (.armed, .triggerDown):
            return true  // Electron apps deliver each flagsChanged twice; the repeat changes nothing
        case (.recording, .triggerDown):
            if handsFree { stopPending = true }  // the stopping tap; it stops on release (W21)
            return true
        case (.armed, .triggerUp):
            // A lone tap, shorter than minimumHold: hands-free recording until the next tap (W20).
            handsFree = true
            beginRecording()
            return true
        case (.armed, _):
            reset()  // Shift+letter (a capital) or a shortcut: the key goes to the app
            return false
        case (.recording, .triggerUp):
            // In hands-free mode only the release of a second press stops; a repeated up of the
            // starting tap changes nothing (W22).
            guard !handsFree || stopPending else { return true }
            finishRecording()
            return true
        case (.recording, .escape):
            recorder.cancel()
            reset()
            host?.showVoiceBar(.hidden)
            return true
        case (.recording, _):
            recorder.cancel()
            reset()
            host?.showVoiceBar(.hidden)
            return false
        case (.idle, .escape), (.idle, .otherKey):
            clearError()
            return false
        default:
            return false
        }
    }

    /// Focus left the client, or ✕ on the bar (W12): stop and discard whatever is in progress.
    public func cancel() {
        if state == .recording { recorder.cancel() }
        if state == .recording || state == .recognizing { host?.showVoiceBar(.hidden) }
        task?.cancel()
        reset()
        clearError()
    }

    /// The microphone band levels, 0…1, from `VoiceSpectrum`; shown smoothed (W17) and only while
    /// recording (W11). The first update ends arming (W16).
    public func updateLevels(_ levels: [Float]) {
        guard state == .recording else { return }
        host?.showVoiceBar(.listening(levels: smoother.smooth(levels)))
    }

    /// Waits for the pending recognition (tests and tools).
    public func settle() async { await task?.value }

    private func reset() {
        state = .idle
        handsFree = false
        stopPending = false
        generation += 1
    }

    private func beginRecording() {
        host?.commitComposition()
        do {
            try recorder.start()
        } catch {
            fail("麥克風無法使用：\(error.localizedDescription)")
            return
        }
        state = .recording
        smoother = LevelSmoother()
        host?.showVoiceBar(.arming)
        let recording = generation
        schedule(Self.maximumRecording) { [weak self] in
            guard let self, self.state == .recording, self.generation == recording else { return }
            self.finishRecording()
        }
    }

    private func finishRecording() {
        let samples = recorder.stop()
        state = .recognizing
        handsFree = false
        stopPending = false
        generation += 1
        let current = generation
        host?.showVoiceBar(.recognizing)
        let audioSeconds = Double(samples.count) / Self.sampleRate
        let started = now()
        let recognizer = recognizer
        task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await recognizer.transcribe(samples)) } catch { result = .failure(error) }
            guard let self, self.state == .recognizing, self.generation == current else { return }
            let seconds = self.now() - started
            switch result {
            case let .success(text):
                self.deliver(text, audioSeconds: audioSeconds, seconds: seconds)
            case let .failure(error):
                self.fail("辨識失敗：\(error.localizedDescription)")
                self.onReport?(VoiceReport(audioSeconds: audioSeconds, recognitionSeconds: seconds, text: nil, error: "\(error)"))
            }
        }
        schedule(Self.recognitionTimeout) { [weak self] in
            guard let self, self.state == .recognizing, self.generation == current else { return }
            self.task?.cancel()
            self.fail("辨識逾時")
            self.onReport?(VoiceReport(audioSeconds: audioSeconds, recognitionSeconds: Self.recognitionTimeout,
                                       text: nil, error: "timeout"))
        }
    }

    private func deliver(_ text: String, audioSeconds: Double, seconds: Double) {
        reset()
        let cleaned = FillerFilter.clean(text)
        host?.showVoiceBar(.hidden)
        if !cleaned.isEmpty {
            host?.commitComposition()
            host?.insertVoiceText(cleaned)
        }
        onReport?(VoiceReport(audioSeconds: audioSeconds, recognitionSeconds: seconds, text: cleaned, error: nil))
    }

    /// Behavior 7: one line for 2 s, nothing sent, keys keep working.
    private func fail(_ message: String) {
        reset()
        showsError = true
        host?.showVoiceBar(.error(message))
        let shown = generation
        schedule(Self.errorDuration) { [weak self] in
            guard let self, self.showsError, self.generation == shown else { return }
            self.clearError()
        }
    }

    private func clearError() {
        guard showsError else { return }
        showsError = false
        host?.showVoiceBar(.hidden)
    }
}

