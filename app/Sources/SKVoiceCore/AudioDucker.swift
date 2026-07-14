import Foundation
import CoreAudio
import AppKit

/// Ducks system output volume while dictating and restores the exact prior level on
/// release — like Siri ducking your music. Skipped when a call app is actively using the
/// microphone, so dictating mid-meeting never silences the other participants.
public final class AudioDucker: @unchecked Sendable {
    /// Injectable volume/call backend so the duck/restore state machine is unit-testable.
    public struct Backend: Sendable {
        public var getVolume: @Sendable () -> Float?
        public var setVolume: @Sendable (Float) -> Bool
        public var callActive: @Sendable () -> Bool

        public init(getVolume: @escaping @Sendable () -> Float?,
                    setVolume: @escaping @Sendable (Float) -> Bool,
                    callActive: @escaping @Sendable () -> Bool) {
            self.getVolume = getVolume
            self.setVolume = setVolume
            self.callActive = callActive
        }

        public static let system = Backend(
            getVolume: { SystemVolume.get() },
            setVolume: { SystemVolume.set($0) },
            callActive: { CallDetection.callAppIsUsingMic() })
    }

    private let backend: Backend
    private let duckLevel: Float
    private let lock = NSLock()
    private var savedVolume: Float?

    public init(backend: Backend = .system, duckLevel: Float = 0.1) {
        self.backend = backend
        self.duckLevel = duckLevel
    }

    /// Lower the output volume for a capture. No-op when: already ducked, a call app is
    /// live on the mic, the device has no volume control, or volume is already low.
    public func duck() {
        lock.lock()
        defer { lock.unlock() }
        guard savedVolume == nil,
              !backend.callActive(),
              let current = backend.getVolume(),
              current > duckLevel else { return }
        if backend.setVolume(duckLevel) {
            savedVolume = current
        }
    }

    /// Put the volume back exactly where it was. Safe to call unconditionally.
    public func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let saved = savedVolume else { return }
        savedVolume = nil
        _ = backend.setVolume(saved)
    }
}

/// Default-output-device volume via CoreAudio. Returns nil/false for devices without a
/// software volume control (some HDMI/DisplayPort outputs) — ducking silently skips.
public enum SystemVolume {
    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    public static func get() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
        else { return nil }
        return volume
    }

    @discardableResult
    public static func set(_ volume: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = volumeAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = Float32(min(max(volume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}

/// Detects an active call by asking Core Audio which processes are capturing the mic
/// (process objects, macOS 14.4+) and matching against call apps and browsers (web
/// meetings). Same technique as SK Note Taker's meeting detection.
public enum CallDetection {
    private static let callAppFragments = [
        "us.zoom", "com.microsoft.teams", "com.apple.FaceTime", "net.whatsapp",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "org.telegram", "com.webex",
        "com.cisco", "com.skype", "com.google.Chrome", "com.apple.Safari",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.brave.Browser",
    ]

    public static func callAppIsUsingMic() -> Bool {
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.saqibkamran.skvoice"
        return bundleIdsUsingMic()
            .filter { $0 != ownBundle }
            .contains { id in callAppFragments.contains { id.hasPrefix($0) } }
    }

    /// Bundle identifiers of processes currently capturing the microphone.
    public static func bundleIdsUsingMic() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            system, &address, 0, nil, &dataSize, &processObjects) == noErr else { return [] }

        var result: [String] = []
        for processObject in processObjects where processObject != kAudioObjectUnknown {
            var runAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                processObject, &runAddress, 0, nil, &size, &running) == noErr,
                  running != 0 else { continue }

            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(
                processObject, &pidAddress, 0, nil, &size, &pid) == noErr, pid > 0
            else { continue }
            if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                result.append(bundleID)
            }
        }
        return result
    }
}
