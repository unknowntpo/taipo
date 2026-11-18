import Foundation

/// Spec 027: the system output device, as far as muting goes. The CoreAudio adapter lives in
/// TaipoVoice; tests use a fake. Devices are named by their persistent UID, never by their name.
public protocol OutputMuteDevice: AnyObject {
    /// The UID of the current default output device, or nil if there is none.
    func defaultOutputUID() -> String?
    /// The main-element output mute of the device, or nil when the device is gone, has no
    /// settable mute, or the read fails (Behavior 6).
    func isMuted(uid: String) -> Bool?
    /// Sets the main-element output mute. Returns false when the device is gone or the write fails.
    func setMuted(_ muted: Bool, uid: String) -> Bool
}

/// What `MutingRecorder` reports (Behavior 8). Carries no device name or UID.
public enum OutputMuteEvent: Equatable, Sendable {
    case muted, restored, skipped
}

/// Spec 027 D3: wraps a `VoiceRecorder` and mutes the default output device while it records.
public final class MutingRecorder: VoiceRecorder {
    /// The `UserDefaults` key holding the UID of the device Taipo muted (Behavior 5).
    public static let markerKey = "outputMutedByTaipoUID"

    private let inner: VoiceRecorder
    private let device: OutputMuteDevice
    private let defaults: UserDefaults
    private let onEvent: (OutputMuteEvent) -> Void

    /// The UID of the device this recorder muted; nil when Taipo has nothing to undo (Behavior 2, H20).
    private var mutedUID: String?

    public init(wrapping inner: VoiceRecorder, device: OutputMuteDevice, defaults: UserDefaults,
                onEvent: @escaping (OutputMuteEvent) -> Void = { _ in }) {
        self.inner = inner
        self.device = device
        self.defaults = defaults
        self.onEvent = onEvent
    }

    /// Behavior 1: mute before the microphone starts; Behavior 3: undo it if the start fails.
    public func start() throws {
        if mutedUID == nil { mute() }
        do {
            try inner.start()
        } catch {
            restore()
            throw error
        }
    }

    /// Behavior 7: the inner samples pass through unchanged. Unmutes after the microphone stops.
    public func stop() -> [Float] {
        let samples = inner.stop()
        restore()
        return samples
    }

    public func cancel() {
        inner.cancel()
        restore()
    }

    private func mute() {
        guard let uid = device.defaultOutputUID(), let muted = device.isMuted(uid: uid) else {
            onEvent(.skipped)  // Behavior 6
            return
        }
        guard !muted else { return }  // Behavior 2: the user's own mute is left alone
        // Behavior 5: write the marker first, so a crash right after the write still recovers.
        defaults.set(uid, forKey: Self.markerKey)
        guard device.setMuted(true, uid: uid) else {
            defaults.removeObject(forKey: Self.markerKey)
            onEvent(.skipped)  // Behavior 6, H17
            return
        }
        mutedUID = uid
        onEvent(.muted)
    }

    /// Behavior 4: unmute the device Taipo muted, found by UID; a device that is gone is skipped.
    private func restore() {
        guard let uid = mutedUID else { return }
        mutedUID = nil
        Self.unmute(uid: uid, device: device, defaults: defaults, onEvent: onEvent)
    }

    private static func unmute(uid: String, device: OutputMuteDevice, defaults: UserDefaults,
                               onEvent: (OutputMuteEvent) -> Void) {
        onEvent(device.setMuted(false, uid: uid) ? .restored : .skipped)
        defaults.removeObject(forKey: markerKey)
    }

    /// Behavior 5: call once at IME launch. Unmutes the device a previous process muted and did
    /// not restore, then clears the marker. A device that is gone is skipped (H19).
    public static func recoverAfterCrash(device: OutputMuteDevice, defaults: UserDefaults,
                                         onEvent: (OutputMuteEvent) -> Void = { _ in }) {
        guard let uid = defaults.string(forKey: markerKey) else { return }
        unmute(uid: uid, device: device, defaults: defaults, onEvent: onEvent)
    }
}
