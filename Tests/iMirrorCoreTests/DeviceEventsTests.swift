import XCTest
@testable import iMirrorCore

final class DeviceReasonTests: XCTestCase {
    func testReadyHasNoReason() {
        XCTAssertNil(deviceReason(DeviceReasonInputs(ready: true, gaveUp: true, usbReset: true)))
    }

    func testFirstBootIsBooting() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false)), .booting)
    }

    func testAnOutageAfterWorkingIsAWedge() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, everConnected: true)), .wdaWedged)
    }

    func testARestartInProgressIsRecovering() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, restarting: true, everConnected: true)),
                       .recovering)
    }

    func testNoTunnelRouteBeatsRecovering() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, tunnelHasDevice: false, restarting: true)),
                       .tunnelDown)
    }

    func testUSBResetBeatsTunnelDown() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, usbReset: true, tunnelHasDevice: false)),
                       .usbReset)
    }

    func testGiveUpBeatsEverythingButReady() {
        let i = DeviceReasonInputs(ready: false, gaveUp: true, macAsleep: true, usbReset: true,
                                   tunnelHasDevice: false, restarting: true, everConnected: true)
        XCTAssertEqual(deviceReason(i), .gaveUp)
    }

    func testMacAsleepBeatsUSBReset() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, macAsleep: true, usbReset: true)), .macAsleep)
    }

    func testRawValuesAreTheContractStrings() {
        XCTAssertEqual(DeviceReason.allCases.map(\.rawValue),
                       ["usb_reset", "wda_wedged", "needs_passcode", "locked", "tunnel_down",
                        "mac_asleep", "gave_up", "recovering", "booting", "untrusted", "runner_missing"])
    }
}

final class PublishedStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFirstUpdateIsAChangeFromNothing() {
        var p = PublishedState()
        let c = p.update(state: .starting, reason: .booting, now: t0)
        XCTAssertEqual(c, PublishedState.Change(from: nil, fromReason: nil, to: .starting, toReason: .booting))
        XCTAssertEqual(p.since, t0)
    }

    func testSameStateAndReasonKeepsSince() {
        var p = PublishedState()
        _ = p.update(state: .down, reason: .wdaWedged, now: t0)
        XCTAssertNil(p.update(state: .down, reason: .wdaWedged, now: t0 + 30))
        XCTAssertEqual(p.since, t0)
    }

    func testAReasonChangeAloneIsAChange() {
        var p = PublishedState()
        _ = p.update(state: .down, reason: .wdaWedged, now: t0)
        let c = p.update(state: .down, reason: .recovering, now: t0 + 30)
        XCTAssertEqual(c?.fromReason, .wdaWedged)
        XCTAssertEqual(c?.toReason, .recovering)
        XCTAssertEqual(p.since, t0 + 30)
    }
}

final class DeviceEventCodecTests: XCTestCase {
    func testLineIsOneCompactSortedObject() {
        let e = DeviceEvent(at: Date(timeIntervalSince1970: 1_790_631_000.25), udid: "U-1", alias: "phone2",
                            event: .usbReset, expected: true)
        let text = String(decoding: DeviceEventCodec.line(e), as: UTF8.self)
        XCTAssertEqual(text, #"{"alias":"phone2","event":"usb_reset","expected":true,"#
                           + #""ts":"2026-09-28T21:30:00.250Z","udid":"U-1"}"# + "\n")
    }

    func testRunnerUpgradeEventCarriesVersions() {
        let e = DeviceEvent(at: Date(timeIntervalSince1970: 0), udid: "U", alias: "phone1",
                            event: .runnerUpgrade, from: "1.0", to: "16.14.2")
        let text = String(decoding: DeviceEventCodec.line(e), as: UTF8.self)
        XCTAssertEqual(text, #"{"alias":"phone1","event":"runner_upgrade","from":"1.0","#
                           + #""to":"16.14.2","ts":"1970-01-01T00:00:00.000Z","udid":"U"}"# + "\n")
    }

    func testStateEventCarriesFromToReason() throws {
        let e = DeviceEvent(at: Date(timeIntervalSince1970: 0), udid: "U", alias: "a", event: .state,
                            from: "ready", to: "down", reason: "wda_wedged")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: DeviceEventCodec.line(e)) as? [String: Any])
        XCTAssertEqual(obj["event"] as? String, "state")
        XCTAssertEqual(obj["from"] as? String, "ready")
        XCTAssertEqual(obj["to"] as? String, "down")
        XCTAssertEqual(obj["reason"] as? String, "wda_wedged")
    }

    func testDetailIsOneBoundedLine() {
        let e = DeviceEvent(at: Date(), udid: "U", alias: "a", event: .restart,
                            detail: "a\nb" + String(repeating: "x", count: 1_000))
        let d = try! XCTUnwrap(e.detail)
        XCTAssertFalse(d.contains("\n"))
        XCTAssertLessThanOrEqual(d.count, DeviceEvent.maxDetail + 1)
    }

    func testRotatesOnlyPastFiveMegabytes() {
        let limit = DeviceEventCodec.rotateAtBytes
        XCTAssertEqual(limit, 5 * 1024 * 1024)
        XCTAssertFalse(DeviceEventCodec.shouldRotate(currentSize: 0, adding: 10_000_000))
        XCTAssertFalse(DeviceEventCodec.shouldRotate(currentSize: limit - 100, adding: 100))
        XCTAssertTrue(DeviceEventCodec.shouldRotate(currentSize: limit - 100, adding: 101))
    }
}

final class ExpectedResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_631_000)

    private func note(_ until: String) -> Data { Data(#"{"until":"\#(until)","by":"devicectl install"}"#.utf8) }

    func testANoteInTheFutureHolds() {
        XCTAssertTrue(ExpectedReset.holds(note("2026-09-28T21:31:30Z"), now: now))
        XCTAssertTrue(ExpectedReset.holds(note("2026-09-28T21:31:30.500Z"), now: now))
    }

    func testAnExpiredMissingOrBrokenNoteDoesNot() {
        XCTAssertFalse(ExpectedReset.holds(note("2026-09-28T21:29:59Z"), now: now))
        XCTAssertFalse(ExpectedReset.holds(nil, now: now))
        XCTAssertFalse(ExpectedReset.holds(Data("{".utf8), now: now))
        XCTAssertFalse(ExpectedReset.holds(note("soon"), now: now))
    }

    func testANoteTooFarAheadIsIgnored() {
        XCTAssertFalse(ExpectedReset.holds(note("2026-09-28T23:30:00Z"), now: now))
    }

    func testFileNameRefusesPathTricks() {
        XCTAssertEqual(ExpectedReset.fileName(udid: "00008140-0006423002D3401C"), "00008140-0006423002D3401C.json")
        XCTAssertNil(ExpectedReset.fileName(udid: "../devices"))
        XCTAssertNil(ExpectedReset.fileName(udid: ""))
    }
}

final class RegistryOwnerTests: XCTestCase {
    /// The MCP server checks owner_uniqueid when present, so a reused pid
    /// is not mistaken for the app.
    func testOwnerUniqueIDIsWrittenAsAnInteger() throws {
        let file = DeviceRegistryFile(ownerPid: 7, ownerUniqueID: 123_456_789_012, appVersion: "x",
                                      updatedAt: "t", goios: nil, devices: [])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: DeviceRegistryCodec.encode(file)) as? [String: Any])
        XCTAssertEqual((obj["owner_uniqueid"] as? NSNumber)?.uint64Value, 123_456_789_012)
        XCTAssertEqual(try DeviceRegistryCodec.decode(DeviceRegistryCodec.encode(file)), file)
    }

    func testGaveUpEntryCarriesNextRetry() throws {
        let d = RegisteredDevice(udid: "U", alias: "a", kind: .device, wdaURL: "http://127.0.0.1:8100",
                                 state: .failed, reason: "gave_up", lastError: "boom",
                                 nextRetryAt: "2026-09-28T21:32:00Z")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any])
        XCTAssertEqual(obj["next_retry_at"] as? String, "2026-09-28T21:32:00Z")
        XCTAssertEqual(obj["last_error"] as? String, "boom")
        XCTAssertEqual(obj["reason"] as? String, "gave_up")
    }
}
