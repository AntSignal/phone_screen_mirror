import XCTest
@testable import iMirrorCore

private let phone2 = "00008140-0006423002D3401C"
private let phone3 = "00008020-000324610A68002E"

final class RegistryProblemTests: XCTestCase {
    func testSlotResultsBecomeProblems() {
        XCTAssertNil(RegistryProblem.slot(.assigned(slot: PortSlot(1), alias: "phone2", isNew: false), udid: phone2))
        XCTAssertEqual(RegistryProblem.slot(.conflict(slot: PortSlot(2), port: 8121), udid: phone3),
                       RegistryProblem(udid: phone3, reason: .slotConflict,
                                       message: "port 8121 (its slot 2) is held by another process"))
        let full = RegistryProblem.slot(.full, udid: phone3)
        XCTAssertEqual(full?.reason, "slots_full")
        XCTAssertEqual(full?.message, "all \(PortSlot.maxSlots) port slots belong to attached phones")
    }

    func testTheBundleProblemNamesTheFix() {
        let p = RegistryProblem.appBundleMissing(goios: "/x/iMirror.app/Contents/Resources/ios")
        XCTAssertNil(p.udid)
        XCTAssertEqual(p.reason, "app_bundle_missing")
        XCTAssertTrue(p.message.contains("scripts/run.sh --restart"))
        XCTAssertTrue(p.message.contains("/x/iMirror.app/Contents/Resources/ios"))
    }

    func testListPutsTheAppFirstThenPhonesByUDID() {
        let bundle = RegistryProblem.appBundleMissing(goios: "/ios")
        let a = RegistryProblem.slot(.full, udid: phone2)!, b = RegistryProblem.slot(.full, udid: phone3)!
        XCTAssertEqual(RegistryProblem.list(bundle: bundle, phones: [phone2: a, phone3: b]), [bundle, b, a])
        XCTAssertEqual(RegistryProblem.list(bundle: nil, phones: [:]), [])
    }

    func testProblemsEncodeAsTheReadersExpect() throws {
        let file = DeviceRegistryFile(ownerPid: 1, appVersion: "t", updatedAt: "2026-11-17T00:00:00Z",
                                      goios: nil, devices: [],
                                      problems: [RegistryProblem.appBundleMissing(goios: "/ios"),
                                                 RegistryProblem.slot(.full, udid: phone3)!])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: DeviceRegistryCodec.encode(file)) as? [String: Any])
        let list = try XCTUnwrap(obj["problems"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertNil(list[0]["udid"])                    // app-wide: no udid key
        XCTAssertEqual(list[1]["udid"] as? String, phone3)
        XCTAssertEqual(list[1]["reason"] as? String, "slots_full")
        XCTAssertNotNil(list[1]["message"] as? String)
    }

    /// Older app builds write no `problems`; that must still decode.
    func testAFileWithoutProblemsDecodes() throws {
        let json = #"{"schema":1,"owner_pid":1,"app_version":"t","updated_at":"x","devices":[]}"#
        XCTAssertNil(try DeviceRegistryCodec.decode(Data(json.utf8)).problems)
        let none = DeviceRegistryFile(ownerPid: 1, appVersion: "t", updatedAt: "x", goios: nil, devices: [])
        XCTAssertFalse(String(decoding: try DeviceRegistryCodec.encode(none), as: UTF8.self).contains("problems"))
    }

    func testABundleThatVanishesIsToldOnceAndClearsWhenBack() {
        var w = AppBundleWatch()
        XCTAssertFalse(w.check(binaryExists: true))
        XCTAssertFalse(w.missing)
        XCTAssertTrue(w.check(binaryExists: false))
        XCTAssertTrue(w.missing)
        XCTAssertFalse(w.check(binaryExists: false), "one notification, not one per poll")
        XCTAssertFalse(w.check(binaryExists: true))
        XCTAssertFalse(w.missing)
        XCTAssertFalse(w.check(binaryExists: false), "once per run")
        XCTAssertTrue(w.missing)
    }
}
