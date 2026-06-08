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
            XCTAssertFalse(device.uid.isEmpty, "the device UID should not be empty")
            XCTAssertFalse(device.name.isEmpty, "the device name should not be empty")
            XCTAssertEqual(device.id, device.uid, "Identifiable.id should equal uid")
        }
    }

    func testDeviceUIDsAreUnique() {
        let uids = AudioInputDeviceManager.availableInputDevices().map(\.uid)
        XCTAssertEqual(Set(uids).count, uids.count, "device UIDs should be unique")
    }

    func testDefaultDeviceIsAmongAvailableWhenPresent() {
        let devices = AudioInputDeviceManager.availableInputDevices()
        guard let defaultUID = AudioInputDeviceManager.defaultInputDeviceUID() else {
            // No default input device (e.g. a no-mic environment): skip, not counted as a failure.
            return
        }
        XCTAssertTrue(
            devices.contains(where: { $0.uid == defaultUID }),
            "the system default input device should appear in the available devices list"
        )
    }

    func testKnownUIDResolvesToDeviceID() {
        guard let first = AudioInputDeviceManager.availableInputDevices().first else {
            return // No available devices, skip.
        }
        let resolved = AudioInputDeviceManager.deviceID(forUID: first.uid)
        XCTAssertNotNil(resolved, "an already-enumerated device UID should resolve to an AudioDeviceID")
        if let resolved {
            XCTAssertNotEqual(resolved, AudioDeviceID(kAudioObjectUnknown))
            XCTAssertNotEqual(resolved, 0)
        }
    }

    func testUnknownUIDResolvesToNil() {
        let resolved = AudioInputDeviceManager.deviceID(forUID: "definitely-not-a-real-device-uid-\(UUID().uuidString)")
        XCTAssertNil(resolved, "a non-existent UID should not resolve to a device")
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
