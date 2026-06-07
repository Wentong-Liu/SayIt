import CoreAudio
import XCTest
@testable import SayItCore

/// `AudioInputDeviceManager` 单测。
///
/// 设备枚举依赖宿主硬件，CI/无麦环境可能为空，故只断言**结构不变量**而非具体设备：
/// - 列出的设备 UID/名称非空、UID 唯一；
/// - 系统默认设备（若存在）必在列表中；
/// - 已知设备的 UID 能解析回 `AudioDeviceID`；不存在的 UID 解析为 nil。
/// 真实采集不在此跑，但全部 API 路径需编译并可被调用。
final class AudioInputDeviceManagerTests: XCTestCase {
    func testAvailableDevicesHaveNonEmptyStableFields() {
        let devices = AudioInputDeviceManager.availableInputDevices()
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty, "设备 UID 不应为空")
            XCTAssertFalse(device.name.isEmpty, "设备名不应为空")
            XCTAssertEqual(device.id, device.uid, "Identifiable.id 应即 uid")
        }
    }

    func testDeviceUIDsAreUnique() {
        let uids = AudioInputDeviceManager.availableInputDevices().map(\.uid)
        XCTAssertEqual(Set(uids).count, uids.count, "设备 UID 应唯一")
    }

    func testDefaultDeviceIsAmongAvailableWhenPresent() {
        let devices = AudioInputDeviceManager.availableInputDevices()
        guard let defaultUID = AudioInputDeviceManager.defaultInputDeviceUID() else {
            // 无默认输入设备（如无麦环境）：跳过，不算失败。
            return
        }
        XCTAssertTrue(
            devices.contains(where: { $0.uid == defaultUID }),
            "系统默认输入设备应出现在可用设备列表中"
        )
    }

    func testKnownUIDResolvesToDeviceID() {
        guard let first = AudioInputDeviceManager.availableInputDevices().first else {
            return // 无可用设备，跳过。
        }
        let resolved = AudioInputDeviceManager.deviceID(forUID: first.uid)
        XCTAssertNotNil(resolved, "已枚举到的设备 UID 应能解析为 AudioDeviceID")
        if let resolved {
            XCTAssertNotEqual(resolved, AudioDeviceID(kAudioObjectUnknown))
            XCTAssertNotEqual(resolved, 0)
        }
    }

    func testUnknownUIDResolvesToNil() {
        let resolved = AudioInputDeviceManager.deviceID(forUID: "definitely-not-a-real-device-uid-\(UUID().uuidString)")
        XCTAssertNil(resolved, "不存在的 UID 不应解析出设备")
    }

    func testEmptyUIDResolvesToNil() {
        XCTAssertNil(AudioInputDeviceManager.deviceID(forUID: ""))
    }
}

final class AudioInputDeviceTests: XCTestCase {
    func testEquatableAndIdentity() {
        let a = AudioInputDevice(uid: "uid-1", name: "Mic A")
        let b = AudioInputDevice(uid: "uid-1", name: "Mic A")
        let c = AudioInputDevice(uid: "uid-2", name: "Mic A")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.id, "uid-1")
    }
}
