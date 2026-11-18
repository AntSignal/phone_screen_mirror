import XCTest
@testable import iMirrorCore

// The three phones on the rig: phone1 on Wi-Fi only, phone2 and phone3 on USB.
private let phone1 = "00008150-001928E01404401C"
private let phone2 = "00008140-0006423002D3401C"
private let phone3 = "00008020-000324610A68002E"

private func usb(_ udid: String, _ version: String = "26.6") -> AttachedDevice {
    AttachedDevice(udid: udid, productType: "iPhone", productVersion: version, connection: "USB")
}

/// IOKit's serial for a UDID: the UDID without its dash.
private func serial(_ udid: String) -> String { udid.replacingOccurrences(of: "-", with: "") }

final class DiscoveryTests: XCTestCase {
    func testDetailsListIsUsedAsIsAndOnlyUSBIsReconciled() {
        let wifi = AttachedDevice(udid: phone1, productType: nil, productVersion: "26.6", connection: "Network")
        let r = Discovery.merge(.details([wifi, usb(phone2)]), usbSerials: [], known: [:])
        XCTAssertEqual(r?.usb, [usb(phone2)])
        XCTAssertEqual(r?.held, [])
        XCTAssertEqual(r?.learned, [wifi, usb(phone2)])
    }

    /// A failed or timed-out poll is no news: the old list stays, and no
    /// phone counts a miss toward the two-miss teardown.
    func testAFailedPollChangesNothing() {
        XCTAssertNil(Discovery.merge(.failed, usbSerials: [serial(phone2)], known: [phone2: usb(phone2)]))
    }

    /// The rig's case: phone1's lockdown fails over Wi-Fi, so `list
    /// --details` exits 1. The USB phones must still show up, even on a
    /// fresh start with nothing known.
    func testOnePhoneFailingDoesNotHideTheOthers() {
        let info = [phone2: DeviceProduct(productType: "iPhone17,5", productVersion: "26.6"),
                    phone3: DeviceProduct(productType: "iPhone11,2", productVersion: "18.7.1")]
        let r = Discovery.merge(.udidsOnly([phone1, phone2, phone3], info: info),
                                usbSerials: [serial(phone2), serial(phone3)], known: [:])
        XCTAssertEqual(r?.usb, [
            AttachedDevice(udid: phone2, productType: "iPhone17,5", productVersion: "26.6", connection: "USB"),
            AttachedDevice(udid: phone3, productType: "iPhone11,2", productVersion: "18.7.1", connection: "USB"),
        ])
        // phone1 is not on USB and was never known as USB: not ours.
        XCTAssertEqual(r?.held, [])
    }

    func testAUSBPhoneWhoseInfoFailsIsHeldNotStartedOrDropped() {
        let r = Discovery.merge(.udidsOnly([phone2, phone3], info: [phone3: DeviceProduct(productType: nil, productVersion: "18.7.1")]),
                                usbSerials: [serial(phone2), serial(phone3)], known: [:])
        XCTAssertEqual(r?.usb.map(\.udid), [phone3])
        XCTAssertEqual(r?.held, [phone2])
        XCTAssertEqual(r?.learned.map(\.udid), [phone3])
    }

    func testAKnownPhoneNeedsNoInfoAndKeepsItsDetails() {
        let known = [phone2: usb(phone2, "26.5")]
        XCTAssertEqual(Discovery.needsInfo([phone1, phone2, phone2], known: known), [phone1])
        let r = Discovery.merge(.udidsOnly([phone2], info: [:]), usbSerials: [serial(phone2)], known: known)
        XCTAssertEqual(r?.usb, [usb(phone2, "26.5")])
    }

    /// No IOKit sighting, but known as USB: perhaps it moved to Wi-Fi,
    /// perhaps IOKit is behind. Keep its chain; start nothing.
    func testAKnownUSBPhoneIOKitCannotSeeIsHeld() {
        let r = Discovery.merge(.udidsOnly([phone2], info: [:]), usbSerials: [], known: [phone2: usb(phone2)])
        XCTAssertEqual(r?.usb, [])
        XCTAssertEqual(r?.held, [phone2])
    }

    func testAKnownWiFiPhoneStaysOutOfTheUSBList() {
        let wifi = AttachedDevice(udid: phone1, productType: nil, productVersion: "26.6", connection: "Network")
        let r = Discovery.merge(.udidsOnly([phone1], info: [:]), usbSerials: [], known: [phone1: wifi])
        XCTAssertEqual(r?.usb, [])
        XCTAssertEqual(r?.held, [])
    }

    /// Missing from the plain list means missing: the caller counts a miss.
    func testAPhoneAbsentFromThePlainListIsNeitherPresentNorHeld() {
        let r = Discovery.merge(.udidsOnly([phone3], info: [:]), usbSerials: [serial(phone3)],
                                known: [phone2: usb(phone2), phone3: usb(phone3)])
        XCTAssertEqual(r?.usb.map(\.udid), [phone3])
        XCTAssertFalse(r?.held.contains(phone2) ?? true)
    }

    /// go-ios v1.3.2 `ios info` (main.go printDeviceInfo) prints the lockdown
    /// values as one JSON object, with no ConnectionType. Values made up.
    func testInfoParse() {
        let out = """
        {"level":"debug","msg":"could not open instruments"}
        {"BuildVersion":"22H31","DeviceName":"iPhone","ProductType":"iPhone11,2","ProductVersion":"18.7.1","UniqueDeviceID":"\(phone3)"}
        """
        XCTAssertEqual(GoIOSParsing.deviceProduct(fromInfo: Data(out.utf8)),
                       DeviceProduct(productType: "iPhone11,2", productVersion: "18.7.1"))
        XCTAssertNil(GoIOSParsing.deviceProduct(fromInfo: Data("failed getting info".utf8)))
    }

    /// Plain `ios list` prints bare UDIDs; the existing parser reads them.
    func testPlainListParse() {
        let out = #"{"deviceList":["\#(phone1)","\#(phone2)"]}"#
        XCTAssertEqual(GoIOSParsing.attachedDevices(fromListDetails: Data(out.utf8)).map(\.udid), [phone1, phone2])
    }
}
