import Foundation
import Testing
@testable import TaipoIME

// Spec 012: voice input. Fakes stand in for the microphone, the recognizer, the timer and the client.

@MainActor
final class FakeScheduler {
    private(set) var now = 0.0
    private var items: [(due: Double, seq: Int, work: @MainActor () -> Void)] = []
    private var seq = 0

    func schedule(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
        seq += 1
        items.append((now + delay, seq, work))
    }

    /// Moves time forward, running every timer that falls due, in order.
    func advance(_ seconds: Double) {
        let end = now + seconds
        while let next = items.filter({ $0.due <= end }).min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
            items.removeAll { $0.seq == next.seq }
            now = next.due
            next.work()
        }
        now = end
    }
}

final class FakeRecorder: VoiceRecorder {
    var startError: Error?
    var samples: [Float] = Array(repeating: 0.1, count: 16_000)
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var cancelled = 0
    var isRunning: Bool { started > stopped + cancelled }

    func start() throws {
        if let startError { throw startError }
        started += 1
    }
    func stop() -> [Float] { stopped += 1; return samples }
    func cancel() { cancelled += 1 }
}

struct FakeError: Error {}

final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
    enum Mode { case text(String), fail, hang }
    var mode: Mode
    private(set) var calls = 0
    init(_ mode: Mode) { self.mode = mode }

    func transcribe(_ samples: [Float]) async throws -> String {
        calls += 1
        switch mode {
        case let .text(text): return text
        case .fail: throw FakeError()
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return "too late"
        }
    }
}

@MainActor
final class FakeHost: VoiceHost {
    /// Every call in order: "commit", "bar:arming", "bar:listening", "bar:recognizing", "bar:error",
    /// "bar:hidden", "insert:<text>". Level updates while listening are kept in `levels`, not in the log.
    private(set) var log: [String] = []
    private(set) var bar = VoiceBar.hidden
    private(set) var levels: [[Float]] = []
    var inserted: [String] { log.filter { $0.hasPrefix("insert:") }.map { String($0.dropFirst(7)) } }
    var showsError: Bool { if case .error = bar { true } else { false } }

    func commitComposition() { log.append("commit") }
    func showVoiceBar(_ bar: VoiceBar) {
        let name: String
        switch bar {
        case .hidden: name = "hidden"
        case .arming: name = "arming"
        case let .listening(levels):
            self.levels.append(levels)
            if case .listening = self.bar { self.bar = bar; return }
            name = "listening"
        case .recognizing: name = "recognizing"
        case .error: name = "error"
        }
        self.bar = bar
        log.append("bar:\(name)")
    }
    func insertVoiceText(_ text: String) { log.append("insert:\(text)") }
}

@MainActor
struct Rig {
    let scheduler = FakeScheduler()
    let recorder = FakeRecorder()
    let recognizer: FakeRecognizer
    let host = FakeHost()
    let session: VoiceSession

    init(_ mode: FakeRecognizer.Mode = .text("這個 API 的 timeout 有點 short"), available: Bool = true) {
        recognizer = FakeRecognizer(mode)
        let scheduler = scheduler
        session = VoiceSession(recorder: recorder, recognizer: recognizer, isAvailable: { available },
                               schedule: { scheduler.schedule($0, $1) }, now: { scheduler.now })
        session.host = host
    }

    /// Holds right Shift for `seconds`, then releases it and waits for recognition.
    func hold(_ seconds: Double) async {
        session.handle(.triggerDown)
        scheduler.advance(seconds)
        session.handle(.triggerUp)
        await session.settle()
    }
}

// MARK: - W1 hold / release state machine

@Test("W1: holding right Shift ≥ 0.3 s records, and the result is inserted on release")
@MainActor func holdRecordsAndInserts() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(0.31)
    #expect(rig.recorder.isRunning)
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    #expect(rig.host.inserted == ["這個 API 的 timeout 有點 short"])
    #expect(rig.session.state == .idle)
}

@Test("W1: Electron apps deliver each right-Shift flagsChanged twice; the repeat changes nothing")
@MainActor func duplicatedTriggerEventsAreIgnored() async {
    let rig = Rig()
    #expect(rig.session.handle(.triggerDown))
    #expect(rig.session.handle(.triggerDown), "repeated down while armed")
    #expect(rig.session.state == .armed)
    rig.scheduler.advance(0.31)
    #expect(rig.session.handle(.triggerDown), "repeated down while recording")
    #expect(rig.recorder.isRunning)
    rig.session.handle(.triggerUp)
    #expect(!rig.session.handle(.triggerUp), "repeated up while recognizing")
    await rig.session.settle()
    #expect(rig.host.inserted == ["這個 API 的 timeout 有點 short"])
}

@Test("W1: Esc while recording cancels: audio discarded, Esc consumed, nothing inserted")
@MainActor func escapeCancels() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(1)
    #expect(rig.session.handle(.escape), "Esc is consumed while recording")
    #expect(rig.recorder.cancelled == 1)
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    #expect(rig.recognizer.calls == 0)
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.host.bar == .hidden)
}

@Test("W1: another key while right Shift is held (⇧⌘C) discards the audio and passes the key to the app")
@MainActor func otherKeyWhileHeldPasses() async {
    for wait in [0.1, 1.0] {  // before and after recording starts
        let rig = Rig()
        rig.session.handle(.triggerDown)
        rig.scheduler.advance(wait)
        #expect(!rig.session.handle(.otherKey), "the key goes to the app (held \(wait) s)")
        rig.scheduler.advance(1)
        rig.session.handle(.triggerUp)
        await rig.session.settle()
        #expect(!rig.recorder.isRunning)
        #expect(rig.recognizer.calls == 0)
        #expect(rig.host.inserted.isEmpty)
        #expect(rig.host.bar == .hidden)
    }
}

@Test("W1: right Shift while composing commits the composition before recording starts")
@MainActor func commitsCompositionFirst() async {
    let rig = Rig()
    await rig.hold(1)
    #expect(Array(rig.host.log.prefix(2)) == ["commit", "bar:arming"])
}

@Test("W1: recording stops by itself at 60 s and is recognized; the later release does nothing")
@MainActor func sixtySecondCap() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(0.3 + 59.9)
    #expect(rig.recorder.isRunning, "still recording just before the cap")
    rig.scheduler.advance(0.2)
    #expect(rig.recorder.stopped == 1)
    await rig.session.settle()
    #expect(rig.host.inserted.count == 1)
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    #expect(rig.recognizer.calls == 1)
    #expect(rig.host.inserted.count == 1)
}

@Test("W1: right Shift flag changes map to down / up; with another modifier held it is not a trigger",
      arguments: [
        (UInt16(60), UInt(0x20104), VoiceEvent.triggerDown),  // right ⇧ alone
        (UInt16(60), UInt(0x100), VoiceEvent.triggerUp),
        (UInt16(60), UInt(0x20000), VoiceEvent.triggerDown),  // right ⇧ alone, no device bits
        (UInt16(60), UInt(0x0), VoiceEvent.triggerUp),  // released, no device bits
        (UInt16(60), UInt(0x120000), VoiceEvent.otherKey),  // ⌘ held, no device bits
        (UInt16(60), UInt(0x120114), VoiceEvent.otherKey),  // ⌘ held, then right ⇧
        (UInt16(60), UInt(0x60105), VoiceEvent.otherKey),  // ⌃ held, then right ⇧
        (UInt16(60), UInt(0xA0124), VoiceEvent.otherKey),  // ⌥ held, then right ⇧
        (UInt16(60), UInt(0x820104), VoiceEvent.otherKey),  // fn held, then right ⇧
        (UInt16(56), UInt(0x20102), VoiceEvent.otherKey),  // left ⇧ alone
        (UInt16(54), UInt(0x100110), VoiceEvent.otherKey),  // right ⌘ alone (the old trigger)
        (UInt16(56), UInt(0x20106), VoiceEvent.otherKey),  // left ⇧ pressed while right ⇧ held
      ])
func rightShiftEdges(keyCode: UInt16, flags: UInt, expected: VoiceEvent) {
    #expect(RightShift.event(keyCode: keyCode, flags: flags) == expected)
}

@Test("W1: right Shift + letter within 0.3 s types a capital: the letter goes to the app, nothing recorded")
@MainActor func capitalLetterPassesThrough() async {
    let rig = Rig()
    #expect(RightShift.event(keyCode: 60, flags: 0x20104) == .triggerDown)
    rig.session.handle(.triggerDown)
    #expect(rig.session.state == .armed)
    rig.scheduler.advance(0.1)
    #expect(!rig.session.handle(.otherKey), "the letter keyDown is not consumed")
    #expect(rig.session.state == .idle)
    rig.scheduler.advance(1)
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    #expect(rig.recorder.started == 0)
    #expect(rig.recognizer.calls == 0)
    #expect(rig.host.log.isEmpty, "no commit, no bar")
}

// MARK: - W2 filler post-processing

@Test("W2: standalone 嗯 / 呃 / 欸 are deleted, words containing them are kept, ends are trimmed",
      arguments: [
        ("嗯，這個 API 的 timeout 有點 short", "這個 API 的 timeout 有點 short"),
        ("  這個 API 的 timeout 有點 short  ", "這個 API 的 timeout 有點 short"),
        ("我覺得，呃，可以", "我覺得，可以"),
        ("好，欸。", "好。"),
        ("嗯嗯 好", "好"),
        ("嗯哼，好", "嗯哼，好"),
        ("欸你好", "欸你好"),
        ("沒有贅字", "沒有贅字"),
      ])
func fillerRemoval(input: String, expected: String) {
    #expect(FillerFilter.clean(input) == expected)
}

@Test("W2: a result that is only fillers or blank sends nothing and hides the bar",
      arguments: ["嗯", " 呃。 ", "", "   "])
@MainActor func emptyResultSendsNothing(text: String) async {
    let rig = Rig(.text(text))
    await rig.hold(1)
    #expect(rig.recognizer.calls == 1)
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.host.bar == .hidden)
}

// MARK: - W3 gating

@Test("W3: with the switch off or the model missing, right Shift is not intercepted")
@MainActor func gatedWhenUnavailable() async {
    let rig = Rig(available: false)
    #expect(!rig.session.handle(.triggerDown))
    rig.scheduler.advance(1)
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    #expect(rig.recorder.started == 0)
    #expect(rig.host.log.isEmpty)
    #expect(rig.session.state == .idle)
}

@Test("W3: positive control: switch on and model installed, right Shift is intercepted")
@MainActor func interceptedWhenAvailable() {
    let rig = Rig(available: true)
    #expect(rig.session.handle(.triggerDown))
    #expect(rig.session.state == .armed)
}

@Test("W3: voice is available only when the switch is on and the model file is installed")
func availability() throws {
    let suite = "taipo-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-voice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = dir.appendingPathComponent(VoiceSettings.modelFileName)

    #expect(!VoiceSettings.isEnabled(in: defaults), "default off")
    try Data([1]).write(to: model)
    #expect(!VoiceSettings.isAvailable(defaults: defaults, modelURL: model), "off, model present")
    defaults.set(true, forKey: VoiceSettings.enabledKey)
    #expect(VoiceSettings.isAvailable(defaults: defaults, modelURL: model), "on, model present")
    try FileManager.default.removeItem(at: model)
    #expect(!VoiceSettings.isAvailable(defaults: defaults, modelURL: model), "on, model missing")
}

// MARK: - W6 failure path

@Test("W6: the recognizer throws: no text, an error line for 2 s, keys work afterwards")
@MainActor func recognizerThrows() async {
    let rig = Rig(.fail)
    await rig.hold(1)
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.host.showsError)
    rig.scheduler.advance(1.9)
    #expect(rig.host.showsError, "still shown before 2 s")
    rig.scheduler.advance(0.2)
    #expect(rig.host.bar == .hidden, "gone after 2 s")
    #expect(!rig.session.handle(.otherKey), "typing passes through")
    #expect(rig.session.state == .idle)
}

@Test("W6: recognition over 10 s times out: no text, error shown, the late result is dropped, keys work",
      .timeLimit(.minutes(1)))  // without the timeout the hanging recognizer would block settle() forever
@MainActor func recognizerTimesOut() async {
    let rig = Rig(.hang)
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(1)
    rig.session.handle(.triggerUp)
    rig.scheduler.advance(9.9)
    #expect(rig.host.bar == .recognizing)
    rig.scheduler.advance(0.2)
    await rig.session.settle()
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.host.showsError)
    #expect(!rig.session.handle(.otherKey))
    #expect(rig.host.bar == .hidden, "typing clears the error line")
    #expect(rig.session.state == .idle)
}

@Test("W6: the microphone cannot start (denied): error shown, nothing recognized, keys work")
@MainActor func microphoneFails() async {
    let rig = Rig()
    rig.recorder.startError = FakeError()
    await rig.hold(1)
    #expect(rig.recognizer.calls == 0)
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.host.showsError)
    rig.scheduler.advance(2.1)
    #expect(rig.host.bar == .hidden)
    #expect(!rig.session.handle(.otherKey))
}

@Test("W6: positive control: after a failure, the next successful recognition inserts its text")
@MainActor func successAfterFailure() async {
    let rig = Rig(.fail)
    await rig.hold(1)
    rig.scheduler.advance(2.1)
    rig.recognizer.mode = .text("好")
    await rig.hold(1)
    #expect(rig.host.inserted == ["好"])
}

// MARK: - W11 floating bar state

@Test("W11: the bar follows the session: arming once recording starts, recognizing after release, hidden before the insert")
@MainActor func barFollowsSession() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(0.29)
    #expect(rig.host.bar == .hidden, "not shown before 0.3 s")
    rig.scheduler.advance(0.02)
    #expect(rig.host.bar == .arming)
    rig.session.handle(.triggerUp)
    #expect(rig.host.bar == .recognizing)
    await rig.session.settle()
    #expect(rig.host.log == ["commit", "bar:arming", "bar:recognizing", "bar:hidden", "commit",
                             "insert:這個 API 的 timeout 有點 short"])
}

@Test("W11: microphone levels update the bar only while recording")
@MainActor func levelOnlyWhileRecording() async {
    let rig = Rig()
    rig.session.updateLevels(bands(0.9))  // idle
    rig.session.handle(.triggerDown)
    rig.session.updateLevels(bands(0.8))  // armed
    #expect(rig.host.log.isEmpty)
    rig.scheduler.advance(0.31)
    rig.session.updateLevels(bands(1))
    #expect(rig.host.bar.isListening(bands(0.3)), "positive control: recording shows the levels")
    rig.session.handle(.triggerUp)
    rig.session.updateLevels(bands(0.7))  // recognizing
    #expect(rig.host.bar == .recognizing)
    await rig.session.settle()
    rig.session.updateLevels(bands(0.6))  // idle again
    #expect(rig.host.bar == .hidden)
    #expect(rig.host.levels.count == 1)
}

extension VoiceBar {
    /// Listening with these levels, to within float rounding.
    func isListening(_ expected: [Float]) -> Bool {
        guard case let .listening(levels) = self, levels.count == expected.count else { return false }
        return zip(levels, expected).allSatisfy { abs($0 - $1) < 1e-5 }
    }
}

/// The same level in every band.
func bands(_ level: Float) -> [Float] { Array(repeating: level, count: VoiceSpectrum.bandCount) }

// MARK: - W12 ✕

@Test("W12: ✕ while recording cancels: microphone stopped, nothing recognized or inserted, bar hidden")
@MainActor func cancelWhileRecording() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(1)
    rig.session.cancel()
    #expect(rig.recorder.cancelled == 1)
    #expect(rig.host.bar == .hidden)
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    #expect(rig.recognizer.calls == 0)
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.session.state == .idle)
}

@Test("W12: ✕ while recognizing drops the result: nothing inserted, bar hidden")
@MainActor func cancelWhileRecognizing() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(1)
    rig.session.handle(.triggerUp)
    #expect(rig.host.bar == .recognizing)
    rig.session.cancel()
    await rig.session.settle()
    #expect(rig.host.inserted.isEmpty)
    #expect(rig.host.bar == .hidden)
    rig.scheduler.advance(11)
    #expect(rig.host.bar == .hidden, "no timeout error after the cancel")
}

// MARK: - W13 band levels

/// `count` samples of a sine at `hz`, 16 kHz.
func sine(_ hz: Double, amplitude: Float = 0.1, count: Int = VoiceSpectrum.windowSize) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / VoiceSpectrum.sampleRate)) }
}

@Test("W13: silence gives 0 in every band")
func spectrumSilence() {
    var spectrum = VoiceSpectrum()
    let levels = spectrum.feed([Float](repeating: 0, count: VoiceSpectrum.windowSize))
    #expect(levels == bands(0))
}

@Test("W13: a frame is produced only once 512 samples have arrived")
func spectrumNeedsFullWindow() {
    var spectrum = VoiceSpectrum()
    let partial = spectrum.feed(sine(1000, count: 511))
    let complete = spectrum.feed(sine(1000, count: 1))
    let next = spectrum.feed(sine(1000, count: 300))
    #expect(partial == nil, "511 samples")
    #expect(complete != nil, "the 512th sample completes the window")
    #expect(next == nil, "the window starts over")
}

@Test("W13: a sine puts its energy in the band that holds its frequency; bands two or more away stay near 0",
      arguments: [(500.0, 1), (1000.0, 3), (3000.0, 7)])
func spectrumSine(hz: Double, band: Int) throws {
    var spectrum = VoiceSpectrum()
    let frame = spectrum.feed(sine(hz))
    let levels = try #require(frame)
    #expect(levels.firstIndex(of: levels.max()!) == band)
    #expect(levels[band] > 0.5)
    for (i, level) in levels.enumerated() where abs(i - band) >= 2 { #expect(level < 0.01, "band \(i)") }
}

@Test("W13: dB maps from -68 (0) to -30 (1), ×1.3 then ^0.7, clamped to 0…1",
      arguments: [(-80, 0), (-68.5, 0), (-67.5, 0.058), (-49, 0.7397), (-39.5, 0.9824), (-38, 1), (-20, 1)]
        as [(Float, Float)])
func spectrumMapping(db: Float, expected: Float) {
    #expect(abs(VoiceSpectrum.level(db: db) - expected) < 0.001)
}

@Test("W13: each inner band blends 15% of each neighbour; the end bands are kept")
func spectrumBlend() {
    #expect(VoiceSpectrum.blend([0, 0, 0, 1, 0, 0, 0, 0, 0]) == [0, 0, 0.15, 0.7, 0.15, 0, 0, 0, 0])
    #expect(VoiceSpectrum.blend([1, 0, 0, 0, 0, 0, 0, 0, 1]) == [1, 0.15, 0, 0, 0, 0, 0, 0.15, 1])
}

@Test("W13: level updates are throttled to at most 30 per second")
func levelThrottle() {
    var throttle = LevelThrottle()
    let allowed = [10, 10 + 0.033, 10 + 0.034, 10 + 0.05].map { throttle.allow(at: $0) }
    // first, just under 1/30 s after it, just over, and under 1/30 s after the second update
    #expect(allowed == [true, false, true, false])
}

// MARK: - W16 arming

@Test("W16: the bar shows arming from the start of recording until the first microphone levels arrive")
@MainActor func armingUntilFirstLevels() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(0.31)
    #expect(rig.host.bar == .arming)
    rig.scheduler.advance(1)
    #expect(rig.host.bar == .arming, "still arming while no levels arrive")
    rig.session.updateLevels(bands(0.5))
    #expect(rig.host.bar.isListening(bands(0.15)))
    #expect(rig.host.log == ["commit", "bar:arming", "bar:listening"])
}

// MARK: - W17 smoothing

@Test("W17: levels are smoothed as previous × 0.7 + new × 0.3, per band")
func smoothing() {
    var smoother = LevelSmoother()
    let close = { (a: [Float], b: [Float]) in zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 } }
    let first = smoother.smooth(bands(1)), second = smoother.smooth(bands(1)), third = smoother.smooth(bands(0))
    #expect(close(first, bands(0.3)))
    #expect(close(second, bands(0.51)))
    #expect(close(third, bands(0.357)))
}

@Test("W17: each recording starts smoothing from 0")
@MainActor func smoothingRestartsPerRecording() async {
    let rig = Rig()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(0.31)
    rig.session.updateLevels(bands(1))
    rig.session.updateLevels(bands(1))
    #expect(rig.host.bar.isListening(bands(0.51)))
    rig.session.handle(.triggerUp)
    await rig.session.settle()
    rig.session.handle(.triggerDown)
    rig.scheduler.advance(0.31)
    #expect(rig.host.bar == .arming, "the second recording arms again")
    rig.session.updateLevels(bands(1))
    #expect(rig.host.bar.isListening(bands(0.3)))
}

// MARK: - W18 fade generation

@Test("W18: a hide that finishes fading after a new show does not hide the new bar")
func fadeStaleHide() throws {
    var fade = BarFade()
    fade.show()
    let hideToken = fade.hide()
    let hide = try #require(hideToken)
    fade.show(visible: true, opaque: false)
    #expect(fade.fadeOutEnded(hide) != .orderOut)
}

@Test("W18: positive control: a hide with no later show orders the panel out; the newest of two hides wins")
func fadeCurrentHide() throws {
    var fade = BarFade()
    fade.show()
    let firstToken = fade.hide()
    let first = try #require(firstToken)
    #expect(fade.fadeOutEnded(first) == .orderOut)
    fade.show(visible: true, opaque: false)
    let secondToken = fade.hide()
    let second = try #require(secondToken)
    #expect(fade.fadeOutEnded(first) == .ignore)
    #expect(fade.fadeOutEnded(second) == .orderOut)
}

// MARK: - W25 the bar is never left transparent

@Test("W25: hide, then show during the fade-out: the show fades in and the ending fade-out restores the bar")
func fadeShowDuringFadeOut() throws {
    var fade = BarFade()
    fade.show()
    let hideToken = fade.hide()
    let hide = try #require(hideToken)
    let show = fade.show(visible: true, opaque: false)
    #expect(show == .fadeIn)
    #expect(fade.fadeOutEnded(hide) == .restore)
    #expect(fade.isShown)
}

@Test("W25: a show while the bar is marked shown but transparent or ordered out fades it in again")
func fadeSelfHeal() {
    var fade = BarFade()
    fade.show()
    let transparent = fade.show(visible: true, opaque: false)
    let orderedOut = fade.show(visible: false, opaque: true)
    #expect(transparent == .fadeIn)
    #expect(orderedOut == .fadeIn)
}

@Test("W25: positive control: a show while the bar is on screen and opaque only updates it; a second hide does nothing")
func fadeKeepWhenShown() {
    var fade = BarFade()
    let first = fade.show()
    let again = fade.show(visible: true, opaque: true)
    let hide = fade.hide()
    let hideAgain = fade.hide()
    #expect(first == .fadeIn)
    #expect(again == .keep)
    #expect(hide != nil)
    #expect(hideAgain == nil)
}

// MARK: - W20–W24 hands-free (tap to start, tap to stop)

extension Rig {
    /// A lone right-Shift tap: down and up within 0.3 s, each delivered `times` times (Electron sends 2).
    func tap(times: Int = 1) {
        for _ in 0..<times { session.handle(.triggerDown) }
        scheduler.advance(0.1)
        for _ in 0..<times { session.handle(.triggerUp) }
    }
}

@Test("W20: a lone right-Shift tap starts hands-free recording and shows the bar; releasing does not stop it")
@MainActor func tapStartsHandsFree() async {
    let rig = Rig()
    rig.tap()
    #expect(rig.session.state == .recording)
    #expect(rig.recorder.isRunning)
    #expect(rig.host.bar == .arming)
    rig.scheduler.advance(5)
    #expect(rig.recorder.isRunning, "still recording 5 s after the tap")
    #expect(rig.recognizer.calls == 0)
}

@Test("W21: a second lone tap stops and recognizes; the text is inserted")
@MainActor func secondTapStopsAndInserts() async {
    let rig = Rig()
    rig.tap()
    rig.scheduler.advance(3)
    rig.session.handle(.triggerDown)
    #expect(rig.recorder.isRunning, "the press alone does not stop; the release does")
    rig.scheduler.advance(0.1)
    rig.session.handle(.triggerUp)
    #expect(rig.recorder.stopped == 1)
    #expect(rig.host.bar == .recognizing)
    await rig.session.settle()
    #expect(rig.host.inserted == ["這個 API 的 timeout 有點 short"])
    #expect(rig.session.state == .idle)
}

@Test("W21: hands-free recording stops by itself at 60 s and is recognized")
@MainActor func handsFreeSixtySecondCap() async {
    let rig = Rig()
    rig.tap()
    rig.scheduler.advance(59.9)
    #expect(rig.recorder.isRunning)
    rig.scheduler.advance(0.2)
    #expect(rig.recorder.stopped == 1)
    await rig.session.settle()
    #expect(rig.host.inserted.count == 1)
}

@Test("W22: duplicated events (down, down, up, up) count as one tap, both to start and to stop")
@MainActor func duplicatedTapCountsOnce() async {
    let rig = Rig()
    rig.tap(times: 2)
    #expect(rig.session.state == .recording, "one tap starts; the repeated up does not stop it")
    #expect(rig.recorder.started == 1)
    rig.scheduler.advance(2)
    rig.tap(times: 2)
    await rig.session.settle()
    #expect(rig.recorder.started == 1, "the repeated up of the stopping tap does not start again")
    #expect(rig.recorder.stopped == 1)
    #expect(rig.host.inserted == ["這個 API 的 timeout 有點 short"])
    #expect(rig.session.state == .idle)
}

@Test("W23: another key during hands-free recording discards the audio and passes the key to the app")
@MainActor func handsFreeOtherKeyDiscards() async {
    for pressedShift in [false, true] {  // a plain key, or Shift+letter from the stopping tap
        let rig = Rig()
        rig.tap()
        rig.scheduler.advance(1)
        if pressedShift { rig.session.handle(.triggerDown) }
        #expect(!rig.session.handle(.otherKey), "the key goes to the app")
        #expect(rig.recorder.cancelled == 1)
        #expect(rig.host.bar == .hidden)
        if pressedShift { rig.session.handle(.triggerUp) }
        await rig.session.settle()
        #expect(rig.recognizer.calls == 0)
        #expect(rig.host.inserted.isEmpty)
        #expect(rig.session.state == .idle)
        #expect(rig.recorder.started == 1, "the later release does not start a new recording")
    }
}

@Test("W24: Esc during hands-free recording cancels: audio discarded, Esc consumed, nothing inserted")
@MainActor func handsFreeEscapeCancels() async {
    let rig = Rig()
    rig.tap()
    rig.scheduler.advance(1)
    #expect(rig.session.handle(.escape))
    #expect(rig.recorder.cancelled == 1)
    #expect(rig.host.bar == .hidden)
    rig.scheduler.advance(60)
    await rig.session.settle()
    #expect(rig.recognizer.calls == 0)
    #expect(rig.host.inserted.isEmpty)
}

@Test("W24: ✕ during hands-free recording cancels; the next tap starts a new recording")
@MainActor func handsFreeCancelButton() async {
    let rig = Rig()
    rig.tap()
    rig.scheduler.advance(1)
    rig.session.cancel()
    #expect(rig.recorder.cancelled == 1)
    #expect(rig.host.bar == .hidden)
    #expect(rig.session.state == .idle)
    rig.tap()
    #expect(rig.recorder.started == 2, "positive control: a fresh tap starts again")
    #expect(rig.recognizer.calls == 0)
}
