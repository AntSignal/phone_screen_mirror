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
                                 state: .starting, detail: "waiting for WebDriverAgent"),
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
        // Stage 0: own chain only when that can't be the tunnel's fault and others are up.
        XCTAssertEqual(action(stage: 0, others: true, tunnel: true), .restartDeviceChain)
        XCTAssertEqual(action(stage: 0, others: false, tunnel: true), .restartTunnelAndChains)
        XCTAssertEqual(action(stage: 0, others: true, tunnel: false), .restartTunnelAndChains)
        // Stage 1: the tunnel only if it's implicated or nobody would notice.
        XCTAssertEqual(action(stage: 1, others: true, tunnel: false), .restartTunnelAndChains)
        XCTAssertEqual(action(stage: 1, others: false, tunnel: true), .restartTunnelAndChains)
        XCTAssertEqual(action(stage: 1, others: true, tunnel: true), .giveUp)
        XCTAssertEqual(action(stage: 2, others: false, tunnel: false), .giveUp)
    }

    /// With one phone (never any healthy "others") the new ladder must be the
    /// old one: one full restart, then give up.
    func testSinglePhoneMatchesTheSinglePhoneLadder() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        XCTAssertEqual(ladder.tick(now: 89, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 90, othersHealthy: false, tunnelHasDevice: true), .restartTunnelAndChains)
        XCTAssertEqual(nextChainRecoveryAction(downForSec: 90, stage: 0, graceSec: 90), .restartChain)
        ladder.onRunwdaStarted(now: 100)                    // the restarted chain's runwda
        XCTAssertEqual(ladder.tick(now: 189, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 190, othersHealthy: false, tunnelHasDevice: true), .giveUp)
        XCTAssertTrue(ladder.hardStopped)
        XCTAssertEqual(ladder.tick(now: 999, othersHealthy: false, tunnelHasDevice: true), .wait)
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
        ladder.hardStop()
        ladder.forceRetry(now: 10)
        XCTAssertFalse(ladder.hardStopped)
        XCTAssertEqual(ladder.stage, 0)
        XCTAssertEqual(ladder.wedgeSince, 10)
    }

    func testTunnelRestartCooldown() {
        XCTAssertTrue(shouldRestartTunnel(lastAt: nil, now: 5))
        XCTAssertFalse(shouldRestartTunnel(lastAt: 100, now: 219))
        XCTAssertTrue(shouldRestartTunnel(lastAt: 100, now: 220))
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
