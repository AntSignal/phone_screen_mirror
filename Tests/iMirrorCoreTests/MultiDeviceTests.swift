import XCTest
@testable import iMirrorCore

// The two real test phones' UDIDs. Both end in 401C — the resolver on the MCP
// side must not match on that — and they're used here so fixtures look like
// what go-ios actually prints.
private let phone16e = "00008140-0006423002D3401C"
private let phone17 = "00008150-001928E01404401C"
private let sim = "5B3C1F2A-0000-4000-8000-00000000A1B2"

final class DeviceRegistryCodecTests: XCTestCase {
    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mcp-server/testdata/devices.sample.json")
    }

    private var sample: DeviceRegistryFile {
        DeviceRegistryFile(
            ownerPid: 4242, appVersion: "0.6.0", updatedAt: "2026-09-28T21:30:00Z",
            goios: "/Applications/iMirror.app/Contents/Resources/ios",
            devices: [
                RegisteredDevice(udid: phone16e, alias: "phone1", kind: .device,
                                 productType: "iPhone17,5", iosVersion: "26.6", connection: "USB",
                                 slot: 0, wdaURL: "http://127.0.0.1:8100", mjpegPort: 9110,
                                 state: .ready),
                RegisteredDevice(udid: phone17, alias: "phone2", kind: .device,
                                 productType: "iPhone18,3", iosVersion: "26.6", connection: "USB",
                                 slot: 1, wdaURL: "http://127.0.0.1:8110", mjpegPort: 9120,
                                 state: .starting, detail: "waiting for WebDriverAgent",
                                 reason: "booting", stateSince: "2026-09-28T21:29:40Z", chainEpoch: 1),
                RegisteredDevice(udid: sim, alias: "sim", kind: .simulator,
                                 productType: "iPhone 17 Pro", iosVersion: "26.0",
                                 wdaURL: "http://127.0.0.1:8201", state: .ready),
            ])
    }

    /// The Python server decodes this same file (test_multi_device.py
    /// test_golden_sample_decodes), so the two sides can't drift apart.
    func testEncodesTheSharedGoldenFileByteForByte() throws {
        let golden = try Data(contentsOf: goldenURL)
        let encoded = try DeviceRegistryCodec.encode(sample)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), String(decoding: golden, as: UTF8.self))
    }

    func testRoundTrips() throws {
        let decoded = try DeviceRegistryCodec.decode(try DeviceRegistryCodec.encode(sample))
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.schema, DeviceRegistryFile.schemaVersion)
    }

    func testTimestampIsUTCWholeSeconds() {
        let date = Date(timeIntervalSince1970: 1_790_631_000.7)
        XCTAssertEqual(DeviceRegistryCodec.timestamp(date), "2026-09-28T21:30:00Z")
    }
}

final class PortSlotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let allFree: (UInt16) -> Bool = { _ in true }

    func testSlotZeroIsTheSinglePhoneLayout() {
        let s = PortSlot(0)
        XCTAssertEqual([s.relayPort, s.forwardPort, s.mjpegPort], [8100, 8101, 9110])
        XCTAssertEqual(s.relayURL, "http://127.0.0.1:8100")
        XCTAssertEqual(PortSlot(1).ports, [8110, 8111, 9120])
    }

    func testSlotsNeverReachTheSimulatorPort() {
        let highest = PortSlot(PortSlot.maxSlots - 1)
        XCTAssertLessThan(highest.forwardPort, 8201)
        XCTAssertLessThan(highest.relayPort, 8201)
    }

    func testFirstPhoneGetsSlotZeroAndPhone1() {
        var table = SlotTable()
        XCTAssertEqual(assignSlot(udid: phone16e, table: &table, inUse: [], isPortFree: allFree, now: now),
                       .assigned(slot: PortSlot(0), alias: "phone1", isNew: true))
        XCTAssertEqual(assignSlot(udid: phone17, table: &table, inUse: [0], isPortFree: allFree, now: now),
                       .assigned(slot: PortSlot(1), alias: "phone2", isNew: true))
    }

    func testSlotsAreStickyAcrossUnplugAndReplug() {
        var table = SlotTable()
        _ = assignSlot(udid: phone16e, table: &table, inUse: [], isPortFree: allFree, now: now)
        _ = assignSlot(udid: phone17, table: &table, inUse: [0], isPortFree: allFree, now: now)
        // The 16e goes away; the 17 alone must NOT slide into slot 0.
        XCTAssertEqual(assignSlot(udid: phone17, table: &table, inUse: [], isPortFree: allFree, now: now),
                       .assigned(slot: PortSlot(1), alias: "phone2", isNew: false))
        // A third phone gets a never-used slot, not the absent 16e's.
        XCTAssertEqual(assignSlot(udid: sim, table: &table, inUse: [1], isPortFree: allFree, now: now),
                       .assigned(slot: PortSlot(2), alias: "phone3", isNew: true))
        XCTAssertEqual(assignSlot(udid: phone16e, table: &table, inUse: [1, 2], isPortFree: allFree, now: now),
                       .assigned(slot: PortSlot(0), alias: "phone1", isNew: false))
    }

    func testBusyPortsAreSkippedForANewPhone() {
        var table = SlotTable()
        let result = assignSlot(udid: phone16e, table: &table, inUse: [],
                                isPortFree: { $0 != 8101 }, now: now)   // e.g. a manual iproxy
        XCTAssertEqual(result, .assigned(slot: PortSlot(1), alias: "phone2", isNew: true))
    }

    func testBusyPortOnAKnownPhonesSlotIsAConflictNotAMove() {
        var table = SlotTable(entries: [phone16e: .init(slot: 0, alias: "phone1")])
        XCTAssertEqual(assignSlot(udid: phone16e, table: &table, inUse: [],
                                  isPortFree: { $0 != 8101 }, now: now),
                       .conflict(slot: PortSlot(0), port: 8101))
        XCTAssertEqual(table.entries[phone16e]?.slot, 0)
    }

    func testFullTableReclaimsTheLongestAbsentPhone() {
        var table = SlotTable(entries: [
            "A": .init(slot: 0, alias: "phone1", lastSeen: Date(timeIntervalSince1970: 50)),
            "B": .init(slot: 1, alias: "phone2", lastSeen: Date(timeIntervalSince1970: 10)),
        ])
        let result = assignSlot(udid: "C", table: &table, inUse: [0], isPortFree: allFree,
                                now: now, maxSlots: 2)
        XCTAssertEqual(result, .assigned(slot: PortSlot(1), alias: "phone2", isNew: true))
        XCTAssertNil(table.entries["B"])
    }

    func testFullOfAttachedPhonesIsFull() {
        var table = SlotTable(entries: ["A": .init(slot: 0, alias: "phone1"),
                                        "B": .init(slot: 1, alias: "phone2")])
        XCTAssertEqual(assignSlot(udid: "C", table: &table, inUse: [0, 1], isPortFree: allFree,
                                  now: now, maxSlots: 2), .full)
    }

    func testDefaultAliasAvoidsARenamedPhonesName() {
        var table = SlotTable(entries: ["A": .init(slot: 0, alias: "phone2")])
        XCTAssertEqual(assignSlot(udid: "B", table: &table, inUse: [0], isPortFree: allFree, now: now),
                       .assigned(slot: PortSlot(1), alias: "phone2-2", isNew: true))
    }

    func testAliasRules() {
        let table = SlotTable(entries: [phone16e: .init(slot: 0, alias: "sixteen")])
        XCTAssertNil(validateAlias("seventeen", forUDID: phone17, in: table))
        XCTAssertNil(validateAlias("sixteen", forUDID: phone16e, in: table))   // its own name
        XCTAssertEqual(validateAlias("sixteen", forUDID: phone17, in: table), .taken(byUDID: phone16e))
        XCTAssertEqual(validateAlias("Phone", forUDID: phone17, in: table), .badFormat)
        XCTAssertEqual(validateAlias("2phone", forUDID: phone17, in: table), .badFormat)
        XCTAssertEqual(validateAlias("my phone", forUDID: phone17, in: table), .badFormat)
        XCTAssertEqual(validateAlias("", forUDID: phone17, in: table), .badFormat)
        XCTAssertEqual(validateAlias(String(repeating: "a", count: 25), forUDID: phone17, in: table), .badFormat)
        XCTAssertEqual(validateAlias("beef", forUDID: phone17, in: table), .looksLikeUDID)
        XCTAssertNil(validateAlias("bee", forUDID: phone17, in: table))
    }

    /// phone-2 and phone_2 read the same PHONE_2_PASSCODE: one phone
    /// would type the other's code, a wrong attempt.
    func testAnAliasMayNotShareAnotherPhonesPasscodeKey() {
        let table = SlotTable(entries: [phone16e: .init(slot: 1, alias: "phone-2")])
        XCTAssertEqual(validateAlias("phone_2", forUDID: phone17, in: table), .taken(byUDID: phone16e))
        XCTAssertNil(validateAlias("phone_2", forUDID: phone16e, in: table), "its own key")
        XCTAssertNil(validateAlias("phone2", forUDID: phone17, in: table), "PHONE2 is another key")
    }

    func testSlotTablePersistsAsJSON() throws {
        let table = SlotTable(entries: [phone16e: .init(slot: 0, alias: "phone1", lastSeen: now)])
        let data = try JSONEncoder().encode(table)
        XCTAssertEqual(try JSONDecoder().decode(SlotTable.self, from: data), table)
    }
}

final class GoIOSParsingTests: XCTestCase {
    func testListDetails() {
        let json = """
        {"deviceList":[{"Udid":"\(phone16e)","ProductName":"iPhone OS","ProductType":"iPhone17,5","ProductVersion":"26.6","ConnectionType":"USB"},
        {"Udid":"\(phone17)","ProductName":"iPhone OS","ProductType":"iPhone18,3","ProductVersion":"26.6","ConnectionType":"Network"}]}
        """
        let devices = GoIOSParsing.attachedDevices(fromListDetails: Data(json.utf8))
        XCTAssertEqual(devices, [
            AttachedDevice(udid: phone16e, productType: "iPhone17,5", productVersion: "26.6", connection: "USB"),
            AttachedDevice(udid: phone17, productType: "iPhone18,3", productVersion: "26.6", connection: "Network"),
        ])
        XCTAssertEqual(devices.map(\.isUSB), [true, false])
    }

    /// Captured from go-ios v1.3.2 (`ios list --details`, 2026-11-14, the 16e
    /// on USB). One JSON line on stdout, nothing on stderr.
    func testListDetailsFromGoIOS132() {
        let out = """
        {"deviceList":[{"Udid":"00008140-0006423002D3401C","ProductName":"iPhone OS","ProductType":"iPhone17,5","ProductVersion":"26.6","ConnectionType":"USB"}]}

        """
        XCTAssertEqual(GoIOSParsing.attachedDevices(fromListDetails: Data(out.utf8)), [
            AttachedDevice(udid: phone16e, productType: "iPhone17,5", productVersion: "26.6", connection: "USB"),
        ])
    }

    /// go-ios v1.3.2's agent encodes `[]Tunnel` with json.Encoder, so the
    /// body ends in a newline, and no tunnels is "[]", not null. The shape
    /// is from tunnel.go; the values are a live agent's (2026-11-14).
    func testTunnelsFromGoIOS132() {
        let body = """
        [{"address":"fd7d:b905:6d8c::1","rsdPort":54586,"udid":"00008140-0006423002D3401C","userspaceTun":true,"userspaceTunPort":60172}]

        """
        XCTAssertEqual(GoIOSParsing.tunnelUDIDs(fromTunnels: Data(body.utf8)), [phone16e])
        XCTAssertEqual(GoIOSParsing.tunnelUDIDs(fromTunnels: Data("[]\n".utf8)), [])
    }

    func testLogLinesAroundTheJSONAreSkipped() {
        let out = """
        {"time":"2026-09-28T19:32:44Z","level":"INFO","msg":"no udid specified using first device in list"}
        {"deviceList":["\(phone16e)"]}
        """
        XCTAssertEqual(GoIOSParsing.attachedDevices(fromListDetails: Data(out.utf8)).map(\.udid), [phone16e])
    }

    func testAPhoneOnUSBAndNetworkIsListedOnceAsUSB() {
        let json = """
        {"deviceList":[{"Udid":"\(phone17)","ConnectionType":"Network"},{"Udid":"\(phone17)","ConnectionType":"USB"}]}
        """
        let devices = GoIOSParsing.attachedDevices(fromListDetails: Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].isUSB)
    }

    func testMalformedListIsEmpty() {
        for bad in ["", "not json", "{}", "{\"deviceList\": 3}", "[1,2]"] {
            XCTAssertEqual(GoIOSParsing.attachedDevices(fromListDetails: Data(bad.utf8)), [], bad)
        }
    }

    func testTunnels() {
        let json = """
        [{"address":"fde9:50c5:724a::1","rsdPort":59645,"udid":"\(phone16e)","userspaceTun":true,"userspaceTunPort":60106},
         {"address":"fd00::1","rsdPort":1,"udid":""}]
        """
        XCTAssertEqual(GoIOSParsing.tunnelUDIDs(fromTunnels: Data(json.utf8)), [phone16e])
        XCTAssertEqual(GoIOSParsing.tunnelUDIDs(fromTunnels: Data("{}".utf8)), [])
    }
}

final class DeviceRecoveryTests: XCTestCase {
    private func action(stage: Int, others: Bool, tunnel: Bool, down: TimeInterval = 100) -> DeviceRecoveryAction {
        nextDeviceRecoveryAction(downForSec: down, graceSec: 90, stage: stage,
                                 othersHealthy: others, tunnelHasDevice: tunnel)
    }

    func testWaitsOutTheGrace() {
        XCTAssertEqual(action(stage: 0, others: true, tunnel: true, down: 89), .wait)
    }

    func testTheLadderTable() {
        // Stage 0: own chain first whenever the tunnel lists the phone.
        XCTAssertEqual(action(stage: 0, others: true, tunnel: true), .restartDeviceChain)
        XCTAssertEqual(action(stage: 0, others: false, tunnel: true), .restartDeviceChain)
        XCTAssertEqual(action(stage: 0, others: true, tunnel: false), .restartTunnelAndChains)
        // Stage 1: the tunnel only if it's implicated or nobody would notice.
        XCTAssertEqual(action(stage: 1, others: true, tunnel: false), .restartTunnelAndChains)
        XCTAssertEqual(action(stage: 1, others: false, tunnel: true), .restartTunnelAndChains)
        XCTAssertEqual(action(stage: 1, others: true, tunnel: true), .giveUp)
        XCTAssertEqual(action(stage: 2, others: false, tunnel: false), .giveUp)
    }

    /// One phone used to go straight to a tunnel restart, which relaunches
    /// the runner (and risks its passcode sheet) for nothing when the tunnel
    /// is fine. Own chain, then tunnel, then a timed pause.
    func testOnePhoneRestartsItsOwnChainBeforeTheTunnel() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        XCTAssertEqual(ladder.tick(now: 89, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 90, othersHealthy: false, tunnelHasDevice: true), .restartDeviceChain)
        ladder.onRunwdaStarted(now: 100)                    // the restarted chain's runwda
        XCTAssertEqual(ladder.tick(now: 189, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 190, othersHealthy: false, tunnelHasDevice: true), .restartTunnelAndChains)
        ladder.onRunwdaStarted(now: 200)
        XCTAssertEqual(ladder.tick(now: 290, othersHealthy: false, tunnelHasDevice: true), .giveUp)
        XCTAssertTrue(ladder.hardStopped)
        XCTAssertEqual(ladder.tick(now: 409, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 410, othersHealthy: false, tunnelHasDevice: true), .autoRetry)
    }

    func testMidSessionOutageUsesTheShortGraceAndStartsOnDown() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        ladder.onConnected()
        XCTAssertNil(ladder.wedgeSince)
        ladder.onDown(now: 500)
        XCTAssertEqual(ladder.tick(now: 529, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 530, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        XCTAssertEqual(ladder.stage, 1)
    }

    /// A USB-reset restart mid-session: the fresh runner gets 90 s to boot,
    /// not the 30 s meant for a runner that hung.
    func testARestartOutsideTheLadderGetsTheFullBootGrace() {
        var ladder = ChainLadderState()
        ladder.onConnected()
        ladder.onDown(now: 500)
        ladder.noteOutsideRestart(now: 502)
        ladder.onRunwdaStarted(now: 505)
        XCTAssertEqual(ladder.tick(now: 594, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 595, othersHealthy: true, tunnelHasDevice: true), .giveUp)
    }

    func testFirstBootDownDoesNotStartTheClock() {
        var ladder = ChainLadderState()
        ladder.onDown(now: 5)
        XCTAssertNil(ladder.wedgeSince)
        XCTAssertEqual(ladder.tick(now: 1_000, othersHealthy: false, tunnelHasDevice: false), .wait)
    }

    func testRunwdaRestartReseedsTheClockButNeverTheStage() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        _ = ladder.tick(now: 90, othersHealthy: true, tunnelHasDevice: true)
        XCTAssertEqual(ladder.stage, 1)
        ladder.onRunwdaStarted(now: 95)
        XCTAssertEqual(ladder.stage, 1)
        XCTAssertEqual(ladder.wedgeSince, 95)
    }

    func testForceRetryReArmsAfterGiveUp() {
        var ladder = ChainLadderState()
        ladder.hardStop(now: 5)
        ladder.forceRetry(now: 10)
        XCTAssertFalse(ladder.hardStopped)
        XCTAssertNil(ladder.nextAutoRetryAt)
        // The retry was stage 0, so 90 s of grace.
        XCTAssertEqual(ladder.stage, 1)
        XCTAssertEqual(ladder.wedgeSince, 10)
    }

    /// The 16e's USB resets mid-session. Giving up must not need a human:
    /// it retries by itself after 2 min, then 5 min, then every 10 min.
    func testGiveUpBacksOffTwoThenFiveThenTenMinutes() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        ladder.onConnected()
        ladder.onDown(now: 100)
        XCTAssertEqual(ladder.tick(now: 130, othersHealthy: false, tunnelHasDevice: true), .restartDeviceChain)
        XCTAssertEqual(ladder.tick(now: 220, othersHealthy: false, tunnelHasDevice: true), .restartTunnelAndChains)
        XCTAssertEqual(ladder.tick(now: 310, othersHealthy: false, tunnelHasDevice: true), .giveUp)
        XCTAssertEqual(ladder.nextAutoRetryAt, 430)
        XCTAssertEqual(ladder.tick(now: 429, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 430, othersHealthy: false, tunnelHasDevice: true), .autoRetry)
        XCTAssertFalse(ladder.hardStopped)
        XCTAssertEqual(ladder.wedgeSince, 430)
        // Still down: tunnel, then a 5-minute pause.
        XCTAssertEqual(ladder.tick(now: 520, othersHealthy: false, tunnelHasDevice: true), .restartTunnelAndChains)
        XCTAssertEqual(ladder.tick(now: 610, othersHealthy: false, tunnelHasDevice: true), .giveUp)
        XCTAssertEqual(ladder.tick(now: 909, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 910, othersHealthy: false, tunnelHasDevice: true), .autoRetry)
        // Then 10 minutes, and 10 minutes for good.
        for retry in [1_690.0, 2_470.0] {
            _ = ladder.tick(now: retry - 690, othersHealthy: false, tunnelHasDevice: true)
            XCTAssertEqual(ladder.tick(now: retry - 600, othersHealthy: false, tunnelHasDevice: true), .giveUp)
            XCTAssertEqual(ladder.tick(now: retry - 1, othersHealthy: false, tunnelHasDevice: true), .wait)
            XCTAssertEqual(ladder.tick(now: retry, othersHealthy: false, tunnelHasDevice: true), .autoRetry)
        }
    }

    func testBackoffStartsOverOnceWDAAnswers() {
        var ladder = ChainLadderState()
        ladder.hardStop(now: 0)
        ladder.hardStop(now: 0)
        XCTAssertEqual(ladder.nextAutoRetryAt, 300)
        ladder.onConnected()
        ladder.hardStop(now: 1_000)
        XCTAssertEqual(ladder.nextAutoRetryAt, 1_120)
    }

    /// Never connected (say, the phone wants its passcode for UI Automation)
    /// used to wait for a human forever. The user may answer the sheet, so
    /// it retries on the same backoff.
    func testAPhoneThatNeverWorkedRetriesToo() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        _ = ladder.tick(now: 90, othersHealthy: false, tunnelHasDevice: true)
        _ = ladder.tick(now: 180, othersHealthy: false, tunnelHasDevice: true)
        XCTAssertEqual(ladder.tick(now: 270, othersHealthy: false, tunnelHasDevice: true), .giveUp)
        XCTAssertEqual(ladder.tick(now: 389, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 390, othersHealthy: false, tunnelHasDevice: true), .autoRetry)
    }

    /// A phone the tunnel can't reach used to restart the shared tunnel on
    /// every auto retry, knocking a working phone's WDA down for good.
    func testAnAutoRetryNeverRestartsTheTunnelUnderAWorkingPhone() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        // The first climb may still restart the tunnel, after three own restarts.
        for t in [90.0, 190, 290] {
            XCTAssertEqual(ladder.tick(now: t, othersHealthy: true, tunnelHasDevice: false), .restartDeviceChain)
            ladder.onRunwdaStarted(now: t + 10)
        }
        XCTAssertEqual(ladder.tick(now: 390, othersHealthy: true, tunnelHasDevice: false), .restartTunnelAndChains)
        ladder.onRunwdaStarted(now: 400)
        XCTAssertEqual(ladder.tick(now: 490, othersHealthy: true, tunnelHasDevice: false), .giveUp)
        XCTAssertEqual(ladder.tick(now: 610, othersHealthy: true, tunnelHasDevice: false), .autoRetry)
        XCTAssertFalse(ChainLadderState.retryMayRestartTunnel(giveUps: ladder.giveUps, othersHealthy: true))
        ladder.onRunwdaStarted(now: 615)
        XCTAssertEqual(ladder.tick(now: 705, othersHealthy: true, tunnelHasDevice: false), .giveUp)
        XCTAssertEqual(ladder.giveUps, 2)
    }

    func testAnAutoRetryMayRestartTheTunnelWhenNoOtherPhoneIsUp() {
        XCTAssertTrue(ChainLadderState.retryMayRestartTunnel(giveUps: 0, othersHealthy: true))
        XCTAssertTrue(ChainLadderState.retryMayRestartTunnel(giveUps: 3, othersHealthy: false))
        var ladder = ChainLadderState()
        ladder.hardStop(now: 0)
        XCTAssertEqual(ladder.tick(now: 120, othersHealthy: false, tunnelHasDevice: false), .autoRetry)
        ladder.onRunwdaStarted(now: 125)
        XCTAssertEqual(ladder.tick(now: 215, othersHealthy: false, tunnelHasDevice: false), .restartTunnelAndChains)
    }

    func testTheBackoffTable() {
        XCTAssertEqual(ChainLadderState.autoRetryDelay(afterGiveUps: 1), 120)
        XCTAssertEqual(ChainLadderState.autoRetryDelay(afterGiveUps: 2), 300)
        XCTAssertEqual(ChainLadderState.autoRetryDelay(afterGiveUps: 3), 600)
        XCTAssertEqual(ChainLadderState.autoRetryDelay(afterGiveUps: 50), 600)
    }

    func testTunnelRestartCooldown() {
        XCTAssertTrue(shouldRestartTunnel(lastAt: nil, now: 5))
        XCTAssertFalse(shouldRestartTunnel(lastAt: 100, now: 219))
        XCTAssertTrue(shouldRestartTunnel(lastAt: 100, now: 220))
    }
}

/// 496aaeb restarted a chain on every reset, including the ones our own
/// tunnel and runner starts cause, which could loop.
final class USBResetWatchTests: XCTestCase {
    /// A phone whose WDA answered, last touched by us at t=0.
    private func upPhone() -> USBResetWatch {
        var w = USBResetWatch()
        w.noteOwnUSBChange(now: 0)
        XCTAssertFalse(w.onProbe(answered: true, now: 30))
        return w
    }

    func testAResetSoonAfterOurOwnStartIsIgnored() {
        var w = upPhone()
        w.noteOwnUSBChange(now: 100)                 // e.g. the tunnel respawned
        XCTAssertFalse(w.onProbe(answered: true, now: 101))
        XCTAssertFalse(w.onDetached(now: 104))       // 4 s later: ours
        XCTAssertFalse(w.onReattached(now: 105))
        XCTAssertFalse(w.onProbe(answered: false, now: 108))
        XCTAssertFalse(w.suspect)
    }

    func testAResetWhileStillBootingIsLeftToTheLadder() {
        var w = USBResetWatch()
        w.noteOwnUSBChange(now: 0)                   // runwda spawned
        XCTAssertFalse(w.onDetached(now: 25))        // WDA never answered yet
        XCTAssertFalse(w.onProbe(answered: false, now: 30))
    }

    func testAResetWithWDAStillAnsweringRestartsNothing() {
        var w = upPhone()
        XCTAssertTrue(w.onDetached(now: 100))
        XCTAssertTrue(w.onReattached(now: 101))      // probe now
        XCTAssertFalse(w.onProbe(answered: true, now: 103))
        XCTAssertFalse(w.suspect)
        XCTAssertFalse(w.onProbe(answered: false, now: 106))
    }

    func testAResetThatKilledWDARestartsOnceTheProbeFails() {
        var w = upPhone()
        w.onDetached(now: 100)
        _ = w.onReattached(now: 101)
        XCTAssertTrue(w.onProbe(answered: false, now: 103))
        XCTAssertFalse(w.suspect)
        XCTAssertEqual(w.lastOwnChangeAt, 103)       // the restart is ours
    }

    func testAProbeWhileThePhoneIsAwayDecidesNothing() {
        var w = upPhone()
        w.onDetached(now: 100)
        XCTAssertFalse(w.onProbe(answered: false, now: 102))
        XCTAssertTrue(w.suspect)
        // Gone too long to wait for: the next failure decides.
        XCTAssertTrue(w.onProbe(answered: false, now: 115))
    }

    func testTheResetPairCountsAsOne() {
        var w = upPhone()
        w.onDetached(now: 100)
        _ = w.onReattached(now: 101)
        w.onDetached(now: 103)                       // second half of the pair
        XCTAssertEqual(w.absentSince, 103)
        XCTAssertFalse(w.onProbe(answered: false, now: 103.5))
        _ = w.onReattached(now: 104)
        XCTAssertTrue(w.onProbe(answered: false, now: 106))
    }

    func testTheRestartsOwnResetDoesNotLoop() {
        var w = upPhone()
        w.onDetached(now: 100)
        _ = w.onReattached(now: 101)
        XCTAssertTrue(w.onProbe(answered: false, now: 103))
        // The restart's runner start resets USB again.
        w.noteOwnUSBChange(now: 110)
        XCTAssertFalse(w.onDetached(now: 114))
        XCTAssertFalse(w.onProbe(answered: false, now: 117))
    }

    func testAtMostOneResetRestartPer30Seconds() {
        var w = upPhone()
        w.onDetached(now: 100)
        _ = w.onReattached(now: 101)
        XCTAssertTrue(w.onProbe(answered: false, now: 102))
        XCTAssertFalse(w.onProbe(answered: true, now: 120))   // came back up
        XCTAssertTrue(w.onDetached(now: 125))
        _ = w.onReattached(now: 126)
        XCTAssertFalse(w.onProbe(answered: false, now: 128))  // cooldown
        XCTAssertTrue(w.suspect)                              // still pending
        XCTAssertTrue(w.onProbe(answered: false, now: 132))
    }

    func testOurOwnStopClearsASuspect() {
        var w = upPhone()
        w.onDetached(now: 100)
        w.noteOwnUSBChange(now: 101)                 // e.g. the ladder gave up
        XCTAssertFalse(w.suspect)
        XCTAssertFalse(w.onProbe(answered: false, now: 120))
    }

    func testUSBSerialMapsToTheUDID() {
        XCTAssertTrue(usbSerial("000081400006423002D3401C", matchesUDID: phone16e))
        XCTAssertFalse(usbSerial("000081400006423002D3401C", matchesUDID: phone17))
        let legacy = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        XCTAssertTrue(usbSerial(legacy, matchesUDID: legacy.uppercased()))
        XCTAssertFalse(usbSerial("", matchesUDID: ""))
    }
}

final class ActiveSessionTests: XCTestCase {
    func testReadsTheTopLevelSessionId() {
        XCTAssertEqual(WDAParse.activeSessionId(["sessionId": "S1", "value": ["ready": true]]), "S1")
        XCTAssertNil(WDAParse.activeSessionId(["value": ["ready": true]]))
        XCTAssertNil(WDAParse.activeSessionId(["sessionId": ""]))
        XCTAssertNil(WDAParse.activeSessionId(nil))
    }
}

/// One failed 8 s probe used to mark a phone down, so a slow agent call
/// that kept WDA busy got WDA restarted under it.
final class ProbeStrikesTests: XCTestCase {
    func testDownTakesTwoFailuresInARow() {
        var s = ProbeStrikes()
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 0), .suspect)
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 3), .down)
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 6), .down)
    }

    func testAnAnswerClearsTheStrike() {
        var s = ProbeStrikes()
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 0), .suspect)
        XCTAssertEqual(s.record(.answered, inFlightAtSend: 0, now: 3), .up)
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 6), .suspect)
    }

    func testATimeoutWithNothingElseWaitingIsAFailure() {
        var s = ProbeStrikes()
        XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 0, now: 0), .suspect)
        XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 0, now: 8), .down)
    }

    func testATimeoutBehindOtherRequestsIsBusy() {
        var s = ProbeStrikes()
        for t in stride(from: 0.0, to: 75, by: 8) {
            XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 1, now: t), .busy)
        }
        XCTAssertEqual(s.failures, 0)
    }

    /// Busy for longer than any agent waits is a stuck WDA.
    func testBusyForTooLongCountsAsFailures() {
        var s = ProbeStrikes()
        XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 2, now: 0), .busy)
        XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 2, now: 75), .suspect)
        XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 2, now: 83), .down)
    }

    func testBusyIsNoEvidenceEitherWay() {
        var s = ProbeStrikes()
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 0), .suspect)
        XCTAssertEqual(s.record(.timedOut, inFlightAtSend: 1, now: 3), .busy)
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 0, now: 14), .down)
    }

    func testARefusedConnectionIsNeverBusy() {
        var s = ProbeStrikes()
        XCTAssertEqual(s.record(.failed, inFlightAtSend: 3, now: 0), .suspect)
    }
}

final class InFlightRequestsTests: XCTestCase {
    func testARequestWaitsUntilWDAReplies() {
        var r = InFlightRequests()
        r.clientSent(1)
        r.clientSent(1)                     // a body in a second chunk
        XCTAssertEqual(r.count, 1)
        r.backendSent(1)
        XCTAssertEqual(r.count, 0)
    }

    func testKeepAliveAndSeveralConnections() {
        var r = InFlightRequests()
        r.clientSent(1); r.backendSent(1)
        r.clientSent(1)                     // next request, same connection
        r.clientSent(2)
        XCTAssertEqual(r.count, 2)
        r.closed(2)
        r.closed(2)
        XCTAssertEqual(r.count, 1)
    }
}
