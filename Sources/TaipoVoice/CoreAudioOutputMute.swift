import CoreAudio
import Foundation
import os
import TaipoIME

private let log = Logger(subsystem: "com.unknowntpo.inputmethod.Taipo", category: "voice")

/// Spec 027: the default output device's main-element mute through public CoreAudio properties.
/// Needs no permission (FC4). Logs only OSStatus codes, never a device name or UID (FC7).
public final class CoreAudioOutputMute: OutputMuteDevice {
    public init() {}

    public func defaultOutputUID() -> String? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id),
                    "default output"), id != kAudioObjectUnknown else { return nil }
        address = Self.address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid), "device uid"),
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    public func isMuted(uid: String) -> Bool? {
        guard let id = device(uid: uid) else { return nil }
        var address = Self.muteAddress
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard check(AudioObjectIsPropertySettable(id, &address, &settable), "mute settable"), settable.boolValue else {
            return nil
        }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "mute read") else { return nil }
        return value != 0
    }

    public func setMuted(_ muted: Bool, uid: String) -> Bool {
        guard let id = device(uid: uid) else { return false }
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        return check(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value),
                     "mute write")
    }

    /// The device with this UID, or nil when it is gone.
    private func device(uid: String) -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        guard check(status, "translate uid"), id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func check(_ status: OSStatus, _ step: StaticString) -> Bool {
        if status != noErr { log.error("output mute \(step, privacy: .public) failed: OSStatus \(status, privacy: .public)") }
        return status == noErr
    }

    private static let muteAddress = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
