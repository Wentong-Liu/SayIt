import CoreAudio
import Foundation

/// A lightweight description of an available audio input device.
///
/// `uid` is the stable string identifier CoreAudio assigns to a device (`kAudioDevicePropertyDeviceUID`),
/// which usually stays unchanged across restarts/replugs, making it suitable to persist into ``AppConfig/inputDeviceUID``.
/// `name` is only used for UI display.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// Stable device identifier (used for persistence and for resolving back to an `AudioDeviceID`).
    public let uid: String
    /// Device display name (e.g. "MacBook Pro Microphone").
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Enumerates system audio input devices, resolves UID <-> `AudioDeviceID`, and queries the system default input device.
///
/// All built on CoreAudio's `AudioObjectGetPropertyData`. These queries are read-only and side-effect-free,
/// used both for the device dropdown in the "Microphone" settings section and to bind the input AudioUnit
/// to the chosen device before ``AudioRecorder`` starts. All methods are `static` -- no internal state, each call queries the current system state.
public enum AudioInputDeviceManager {
    /// Lists all current "input-capable" audio devices (in system enumeration order).
    ///
    /// Filter rule: keep only devices with input channel count > 0 (exclude pure output devices such as speakers).
    /// Devices whose UID or name cannot be obtained are skipped (cannot be stably identified/displayed, so meaningless).
    public static func availableInputDevices() -> [AudioInputDevice] {
        deviceIDs().compactMap { deviceID in
            guard hasInputChannels(deviceID),
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
                ?? uid
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// UID of the system's current default input device; nil when there is no default device (e.g. no microphone at all).
    public static func defaultInputDeviceUID() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Resolves a device UID to an `AudioDeviceID`. Returns nil if it cannot be resolved (device unplugged/UID invalid).
    ///
    /// Uses `kAudioHardwarePropertyTranslateUIDToDevice`: translates the passed UID string into a device ID,
    /// which is more direct than enumerating devices one by one and comparing UIDs, and is also Apple's recommended approach.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // The CFString translation requires passing the UID as a qualifier.
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        // Second check: the translated device must actually have input channels (preventing translation to a pure output device).
        guard hasInputChannels(deviceID) else { return nil }
        return deviceID
    }

    // MARK: - CoreAudio private queries

    /// The `AudioDeviceID` of the system default input device; nil if none.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        return deviceID
    }

    /// `AudioDeviceID`s of all system audio devices (regardless of input/output).
    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// Whether the device has > 0 channels in the input scope (used to distinguish input devices from pure output devices).
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard status == noErr else { return false }

        let listPtr = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels > 0
    }

    /// Reads a CFString property of the device (e.g. UID / name). Returns nil on failure.
    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let result = value else { return nil }
        return result as String
    }
}
