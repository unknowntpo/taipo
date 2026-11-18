import Foundation
import Testing
@testable import TaipoIME

// Spec 027: mute the default output device while recording. A fake device stands in for CoreAudio.

final class FakeOutputDevice: OutputMuteDevice {
    var defaultUID: String?
    /// Mute per device UID. A UID missing here is a device that is gone or has no mute property.
    var mutes: [String: Bool]
    var readFails = false
    var writeFails = false
    private(set) var writes: [(uid: String, muted: Bool)] = []
    /// Called before each write is applied.
    var onWrite: (String, Bool) -> Void = { _, _ in }

    init(defaultUID: String? = "builtin", mutes: [String: Bool] = ["builtin": false]) {
        self.defaultUID = defaultUID
        self.mutes = mutes
    }

    func defaultOutputUID() -> String? { defaultUID }
    func isMuted(uid: String) -> Bool? { readFails ? nil : mutes[uid] }
    func setMuted(_ muted: Bool, uid: String) -> Bool {
        onWrite(uid, muted)
        writes.append((uid, muted))
        guard !writeFails, mutes[uid] != nil else { return false }
        mutes[uid] = muted
        return true
    }
}

/// Records what the output device looked like at the moment the inner recorder started.
final class ProbeRecorder: VoiceRecorder {
    var startError: Error?
    var samples: [Float] = [0.25, -0.5, 0.125]
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    private(set) var started = 0, stopped = 0, cancelled = 0

    func start() throws {
        onStart()
        if let startError { throw startError }
        started += 1
    }
    func stop() -> [Float] { onStop(); stopped += 1; return samples }
    func cancel() { onCancel(); cancelled += 1 }
}

final class MuteFixture {
    let suite = "taipo-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let device: FakeOutputDevice
    let inner = ProbeRecorder()
    var events: [OutputMuteEvent] = []
    lazy var recorder = MutingRecorder(wrapping: inner, device: device, defaults: defaults) { [unowned self] in
        self.events.append($0)
    }
    var marker: String? { defaults.string(forKey: MutingRecorder.markerKey) }

    init(device: FakeOutputDevice = FakeOutputDevice()) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        self.device = device
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
}

@Test("H10: unmuted output is muted, and its UID recorded, before the inner recorder starts")
func h10MuteBeforeStart() throws {
    let f = try MuteFixture()
    var mutedAtStart: Bool?
    var markerAtStart: String?
    f.inner.onStart = { mutedAtStart = f.device.mutes["builtin"]; markerAtStart = f.marker }
    try f.recorder.start()
    #expect(mutedAtStart == true)
    #expect(markerAtStart == "builtin")
    #expect(f.inner.started == 1)
    #expect(f.events == [.muted])
}

@Test("H11: stop unmutes, clears the marker, and returns the inner samples unchanged")
func h11StopRestores() throws {
    let f = try MuteFixture()
    try f.recorder.start()
    let samples = f.recorder.stop()
    #expect(samples == [0.25, -0.5, 0.125])
    #expect(f.inner.stopped == 1)
    #expect(f.device.mutes["builtin"] == false)
    #expect(f.marker == nil)
    #expect(f.events == [.muted, .restored])
}

@Test("H12: output already muted by the user is never written and stays muted",
      arguments: [(true, 0), (false, 2)])
func h12UserMuteUntouched(alreadyMuted: Bool, expectedWrites: Int) throws {
    // The `false` row is the positive control: the same path writes when the output was unmuted.
    let f = try MuteFixture(device: FakeOutputDevice(mutes: ["builtin": alreadyMuted]))
    try f.recorder.start()
    #expect(f.marker == (alreadyMuted ? nil : "builtin"))
    _ = f.recorder.stop()
    #expect(f.device.writes.count == expectedWrites)
    #expect(f.device.mutes["builtin"] == alreadyMuted)
    #expect(f.marker == nil)
}

@Test("H13: cancel unmutes and clears the marker")
func h13CancelRestores() throws {
    let f = try MuteFixture()
    try f.recorder.start()
    f.recorder.cancel()
    #expect(f.inner.cancelled == 1)
    #expect(f.device.mutes["builtin"] == false)
    #expect(f.marker == nil)
    #expect(f.events == [.muted, .restored])
}

@Test("H14: when the inner start throws, the error propagates and the output is already unmuted")
func h14StartFailureRestores() throws {
    let f = try MuteFixture()
    f.inner.startError = FakeError()
    #expect(throws: FakeError.self) { try f.recorder.start() }
    #expect(f.device.mutes["builtin"] == false)
    #expect(f.marker == nil)
    #expect(f.events == [.muted, .restored])
}

@Test("H15: when the default output changes mid-recording, stop unmutes the original device only")
func h15RestoresOriginalDevice() throws {
    let f = try MuteFixture(device: FakeOutputDevice(mutes: ["builtin": false, "headphones": false]))
    try f.recorder.start()
    f.device.defaultUID = "headphones"
    _ = f.recorder.stop()
    #expect(f.device.mutes["builtin"] == false)
    #expect(f.device.mutes["headphones"] == false)
    #expect(f.device.writes.map(\.uid) == ["builtin", "builtin"])
    #expect(f.marker == nil)
}

@Test("H15: an original device that is gone at stop is skipped and the marker cleared")
func h15OriginalDeviceGone() throws {
    let f = try MuteFixture()
    try f.recorder.start()
    f.device.mutes["builtin"] = nil
    let samples = f.recorder.stop()
    #expect(samples == [0.25, -0.5, 0.125])
    #expect(f.marker == nil)
}

@Test("H16: no mute property, a failed read, or no default device: recording starts, nothing written",
      arguments: ["no-property", "read-fails", "no-device"])
func h16Unsupported(kind: String) throws {
    let device = FakeOutputDevice()
    switch kind {
    case "no-property": device.mutes = [:]
    case "read-fails": device.readFails = true
    default: device.defaultUID = nil
    }
    let f = try MuteFixture(device: device)
    try f.recorder.start()
    #expect(f.inner.started == 1)
    #expect(f.device.writes.isEmpty)
    #expect(f.marker == nil)
    #expect(f.events == [.skipped])
}

@Test("H17: a failed mute write still records, writes no marker, and stop does not unmute")
func h17WriteFails() throws {
    let f = try MuteFixture()
    f.device.writeFails = true
    try f.recorder.start()
    #expect(f.inner.started == 1)
    #expect(f.marker == nil)
    _ = f.recorder.stop()
    #expect(f.device.writes.count == 1)
    #expect(f.events == [.skipped])
}

@Test("H18: a leftover marker at launch unmutes that device and clears the marker; no marker does nothing")
func h18Recovery() throws {
    let f = try MuteFixture(device: FakeOutputDevice(mutes: ["builtin": true]))
    MutingRecorder.recoverAfterCrash(device: f.device, defaults: f.defaults)
    #expect(f.device.writes.isEmpty, "no marker: nothing written")
    #expect(f.device.mutes["builtin"] == true)

    f.defaults.set("builtin", forKey: MutingRecorder.markerKey)
    var events: [OutputMuteEvent] = []
    MutingRecorder.recoverAfterCrash(device: f.device, defaults: f.defaults) { events.append($0) }
    #expect(f.device.mutes["builtin"] == false)
    #expect(f.marker == nil)
    #expect(events == [.restored])
}

@Test("H19: a leftover marker for a device that is gone is cleared without error")
func h19RecoveryDeviceGone() throws {
    let f = try MuteFixture(device: FakeOutputDevice(mutes: [:]))
    f.defaults.set("unplugged", forKey: MutingRecorder.markerKey)
    MutingRecorder.recoverAfterCrash(device: f.device, defaults: f.defaults)
    #expect(f.marker == nil)
}

@Test("H20: a second stop, or a stop without start, never unmutes a mute the user set")
func h20NoDoubleRestore() throws {
    let f = try MuteFixture()
    try f.recorder.start()
    _ = f.recorder.stop()
    f.device.mutes["builtin"] = true  // the user mutes after recording
    _ = f.recorder.stop()
    f.recorder.cancel()
    #expect(f.device.mutes["builtin"] == true)
    #expect(f.device.writes.count == 2)

    let g = try MuteFixture(device: FakeOutputDevice(mutes: ["builtin": true]))
    _ = g.recorder.stop()
    g.recorder.cancel()
    #expect(g.device.writes.isEmpty)
    #expect(g.device.mutes["builtin"] == true)
}

@Test("H10: the marker is written before the mute write, so a crash between them still recovers")
func h10MarkerWriteAhead() throws {
    let f = try MuteFixture()
    var markerAtMute: String?
    f.device.onWrite = { _, muted in if muted { markerAtMute = f.marker } }
    try f.recorder.start()
    #expect(markerAtMute == "builtin")
}

@Test("H11: the output is still muted while the inner recorder stops; unmuted only afterwards")
func h11MutedDuringStop() throws {
    let f = try MuteFixture()
    var mutedAtStop: Bool?
    f.inner.onStop = { mutedAtStop = f.device.mutes["builtin"] }
    try f.recorder.start()
    _ = f.recorder.stop()
    #expect(mutedAtStop == true)
    #expect(f.device.mutes["builtin"] == false)
}

@Test("H13: the output is still muted while the inner recorder cancels; unmuted only afterwards")
func h13MutedDuringCancel() throws {
    let f = try MuteFixture()
    var mutedAtCancel: Bool?
    f.inner.onCancel = { mutedAtCancel = f.device.mutes["builtin"] }
    try f.recorder.start()
    f.recorder.cancel()
    #expect(mutedAtCancel == true)
    #expect(f.device.mutes["builtin"] == false)
}

@Test("H26: a failed unmute write on a connected device clears the marker, reports skipped, and is not retried")
func h26UnmuteWriteFails() throws {
    let f = try MuteFixture()
    try f.recorder.start()
    f.device.writeFails = true
    _ = f.recorder.stop()
    #expect(f.marker == nil)
    #expect(f.events == [.muted, .skipped])
    _ = f.recorder.stop()
    MutingRecorder.recoverAfterCrash(device: f.device, defaults: f.defaults)
    #expect(f.device.writes.count == 2, "no retry by a second stop or by launch recovery")
}
