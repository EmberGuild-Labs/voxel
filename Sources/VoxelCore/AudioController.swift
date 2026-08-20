import AudioToolbox
import CoreAudio
import Foundation

/// What we did to the audio device, so `restore()` can undo exactly that.
public struct AudioSnapshot {
    public enum Method: String {
        case mute          // device supports a real mute switch -- cleanest
        case virtualMain   // fall back to the HAL's virtual main volume
        case scalar        // fall back to per-channel volume scalars
        case unavailable   // device exposes nothing we can drive
    }

    public var method: Method
    public var wasMuted: Bool?
    public var previousVolume: Float32?
    public var previousChannelVolumes: [UInt32: Float32] = [:]
}

/// Drives the default output device.
///
/// Audio is the first thing to go on panic: it is the only tell that reaches
/// someone before they can see the screen. Every call here is a direct CoreAudio
/// property write -- no permission prompt, no daemon round-trip.
public enum AudioController {

    /// `'vmvc'` -- the HAL's virtual main volume. Lives in AudioToolbox's
    /// AudioHardwareService.h as a C enum, so it needs an explicit conversion.
    private static let virtualMainVolume =
        AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)

    // MARK: - Device lookup

    public static func defaultOutputDevice() -> AudioDeviceID? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard let id: AudioDeviceID = getValue(AudioObjectID(kAudioObjectSystemObject),
                                               address, AudioDeviceID(0)),
              id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    public static func deviceName(_ device: AudioDeviceID) -> String {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Unmanaged, not CFString: CoreAudio hands back a +1 reference and
        // writing directly into an ARC-managed variable is not sound.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
        guard status == noErr, let name else { return "Unknown device" }
        return name.takeRetainedValue() as String
    }

    /// `kAudioDeviceTransportType*` -- tells us whether sound leaves the machine
    /// out loud (built-in speakers) or privately (headphones).
    public static func transportType(_ device: AudioDeviceID) -> UInt32? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return getValue(device, address, UInt32(0))
    }

    /// True when output goes to speakers everyone in the room can hear.
    public static func isAudibleToRoom(_ device: AudioDeviceID) -> Bool {
        guard let transport = transportType(device) else { return true }
        // Built-in is the laptop speakers. Bluetooth/USB could be either
        // headphones or a speaker, so we treat only built-in as definitely loud
        // and let the leak report describe the ambiguous cases.
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    public static func currentVolume(_ device: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if let volume: Float32 = getValue(device, address, Float32(0)) { return volume }

        address.mSelector = kAudioDevicePropertyVolumeScalar
        return getValue(device, address, Float32(0))
    }

    public static func isMuted(_ device: AudioDeviceID) -> Bool? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard let value: UInt32 = getValue(device, address, UInt32(0)) else { return nil }
        return value == 1
    }

    // MARK: - Panic / restore

    /// Silences output and returns what it takes to put things back.
    ///
    /// Tries the real mute switch first because it is a single write and it
    /// preserves the volume level for free.
    @discardableResult
    public static func silence() -> AudioSnapshot {
        guard let device = defaultOutputDevice() else {
            return AudioSnapshot(method: .unavailable)
        }

        let muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if isSettable(device, muteAddress) {
            let wasMuted = isMuted(device) ?? false
            if setValue(device, muteAddress, UInt32(1)) {
                return AudioSnapshot(method: .mute, wasMuted: wasMuted)
            }
        }

        let virtualAddress = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if isSettable(device, virtualAddress),
           let previous: Float32 = getValue(device, virtualAddress, Float32(0)),
           setValue(device, virtualAddress, Float32(0)) {
            return AudioSnapshot(method: .virtualMain, previousVolume: previous)
        }

        // Last resort: walk the individual output channels.
        var snapshot = AudioSnapshot(method: .scalar)
        var scalarAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var touchedAny = false
        for channel in [kAudioObjectPropertyElementMain, 1, 2] {
            scalarAddress.mElement = channel
            guard isSettable(device, scalarAddress),
                  let previous: Float32 = getValue(device, scalarAddress, Float32(0))
            else { continue }
            if setValue(device, scalarAddress, Float32(0)) {
                snapshot.previousChannelVolumes[channel] = previous
                touchedAny = true
            }
        }
        return touchedAny ? snapshot : AudioSnapshot(method: .unavailable)
    }

    public static func restore(_ snapshot: AudioSnapshot) {
        guard let device = defaultOutputDevice() else { return }

        switch snapshot.method {
        case .mute:
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            setValue(device, address, UInt32(snapshot.wasMuted == true ? 1 : 0))

        case .virtualMain:
            let address = AudioObjectPropertyAddress(
                mSelector: virtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            setValue(device, address, snapshot.previousVolume ?? 0.5)

        case .scalar:
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            for (channel, volume) in snapshot.previousChannelVolumes {
                address.mElement = channel
                setValue(device, address, volume)
            }

        case .unavailable:
            break
        }
    }

    // MARK: - CoreAudio plumbing

    private static func getValue<T>(_ objectID: AudioObjectID,
                                    _ address: AudioObjectPropertyAddress,
                                    _ initial: T) -> T? {
        var addr = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func setValue<T>(_ objectID: AudioObjectID,
                                    _ address: AudioObjectPropertyAddress,
                                    _ value: T) -> Bool {
        var addr = address
        var scratch = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &scratch) {
            AudioObjectSetPropertyData(objectID, &addr, 0, nil, size, $0)
        }
        return status == noErr
    }

    private static func isSettable(_ objectID: AudioObjectID,
                                   _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        guard AudioObjectHasProperty(objectID, &addr) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(objectID, &addr, &settable)
        return status == noErr && settable.boolValue
    }
}
