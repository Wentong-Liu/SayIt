import CoreAudio
import Foundation

/// 一个可用的音频输入设备的轻量描述。
///
/// `uid` 是 CoreAudio 给设备分配的稳定字符串标识（`kAudioDevicePropertyDeviceUID`），
/// 跨重启/重新插拔通常保持不变，适合持久化到 ``AppConfig/inputDeviceUID``。
/// `name` 仅用于 UI 展示。
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// 设备稳定标识（持久化与解析回 `AudioDeviceID` 都用它）。
    public let uid: String
    /// 设备展示名（如 “MacBook Pro 麦克风”）。
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// 枚举系统音频输入设备、解析 UID ↔ `AudioDeviceID`、查询系统默认输入设备。
///
/// 全部基于 CoreAudio 的 `AudioObjectGetPropertyData`。这些查询是只读的、无副作用，
/// 既用于「麦克风」设置区的设备下拉，也用于 ``AudioRecorder`` 启动前把输入 AudioUnit
/// 绑定到选定设备。方法均为 `static`——无内部状态，调用即查当下系统状态。
public enum AudioInputDeviceManager {
    /// 列出当前所有「具备输入能力」的音频设备（按系统枚举顺序）。
    ///
    /// 过滤规则：只保留输入声道数 > 0 的设备（排除纯输出设备如扬声器）。
    /// 拿不到 UID 或名称的设备会被跳过（无法稳定标识/展示，无意义）。
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

    /// 系统当前默认输入设备的 UID；无默认设备（如无任何麦克风）时为 nil。
    public static func defaultInputDeviceUID() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// 把设备 UID 解析为 `AudioDeviceID`。解析不到（设备已拔出/UID 失效）返回 nil。
    ///
    /// 用 `kAudioHardwarePropertyTranslateUIDToDevice`：把传入的 UID 字符串翻译成设备 ID，
    /// 比逐个枚举设备再比对 UID 更直接，也是 Apple 推荐方式。
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // CFString 的翻译需要把 UID 作为 qualifier 传入。
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
        // 二次校验：翻译出的设备需确实有输入声道（防止翻译到纯输出设备）。
        guard hasInputChannels(deviceID) else { return nil }
        return deviceID
    }

    // MARK: - CoreAudio 私有查询

    /// 系统默认输入设备的 `AudioDeviceID`；无则 nil。
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

    /// 系统所有音频设备的 `AudioDeviceID`（不区分输入/输出）。
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

    /// 该设备在输入 scope 下是否有 > 0 的声道（用以区分输入设备/纯输出设备）。
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

    /// 读取设备的一个 CFString 属性（如 UID / 名称）。失败返回 nil。
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
