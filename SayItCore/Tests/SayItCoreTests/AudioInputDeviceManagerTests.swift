import CoreAudio
import XCTest
@testable import SayItCore

/// `AudioInputDeviceManager` unit test.
///
/// Device enumeration depends on the host hardware, and may be empty on CI/no-mic environments, so it only asserts **structural invariants** rather than specific devices:
/// - the listed devices' UID/name are non-empty, UID unique;
/// - the system default device (if it exists) must be in the list;
/// - a known device's UID can be resolved back to an `AudioDeviceID`; a non-existent UID resolves to nil.
/// Real capture does not run here, but all API paths must compile and be callable.
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
            // No default input device (e.g. a no-mic environment): skip, not counted as a failure.
            return
        }
        XCTAssertTrue(
            devices.contains(where: { $0.uid == defaultUID }),
            "系统默认输入设备应出现在可用设备列表中"
        )
    }

    func testKnownUIDResolvesToDeviceID() {
        guard let first = AudioInputDeviceManager.availableInputDevices().first else {
            return // No available devices, skip.
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
