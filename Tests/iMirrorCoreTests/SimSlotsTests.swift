import XCTest
@testable import iMirrorCore

private let simA = "5B3C1F2A-0000-4000-8000-00000000A1B2"
private let simB = "0F1E2D3C-1111-4222-8333-444455556666"
private let simC = "ABCDEF01-2345-4678-9ABC-DEF012345678"

final class SimSlotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let allFree: (UInt16) -> Bool = { _ in true }

    func testFirstSimKeepsTheSingleSimPort() {
        XCTAssertEqual(SimSlot(1).wdaPort, 8201)
        XCTAssertEqual(SimSlot(1).wdaURL, "http://127.0.0.1:8201")
        XCTAssertEqual(SimSlot(2).ports, [8202, 9202])
    }

    func testNoSimPortMeetsAnyPhonePort() {
        let phonePorts = Set((0..<PortSlot.maxSlots).flatMap { PortSlot($0).ports })
        let simPorts = (1...SimSlot.maxSims).flatMap { SimSlot($0).ports }
        XCTAssertEqual(Set(simPorts).count, simPorts.count, "two sims share a port")
        XCTAssertTrue(phonePorts.isDisjoint(with: simPorts))
        // WDA's own default MJPEG port, which a sim's WDA would bind without MJPEG_PORT.
        XCTAssertFalse(simPorts.contains(9100))
    }

    func testSimsGetIncreasingPortsAndNameAliases() {
        var table = SimSlotTable()
        XCTAssertEqual(assignSimSlot(udid: simA, name: "iPhone 17 Pro", table: &table, inUse: [],
                                     otherAliases: [], isPortFree: allFree, now: now),
                       .assigned(slot: SimSlot(1), alias: "iphone-17-pro", isNew: true))
        XCTAssertEqual(assignSimSlot(udid: simB, name: "iPad Air 13-inch (M3)", table: &table, inUse: [1],
                                     otherAliases: [], isPortFree: allFree, now: now),
                       .assigned(slot: SimSlot(2), alias: "ipad-air-13-inch-m3", isNew: true))
    }

    func testAKnownSimKeepsItsSlotAndAliasEvenIfItsPortAnswers() {
        var table = SimSlotTable()
        _ = assignSimSlot(udid: simA, name: "iPhone 17", table: &table, inUse: [],
                          otherAliases: [], isPortFree: allFree, now: now)
        _ = assignSimSlot(udid: simB, name: "iPhone 16e", table: &table, inUse: [1],
                          otherAliases: [], isPortFree: allFree, now: now)
        // A left-over runner from the last app run is still on :8201.
        let r = assignSimSlot(udid: simA, name: "renamed in Xcode", table: &table, inUse: [2],
                              otherAliases: [], isPortFree: { $0 != 8201 }, now: now)
        XCTAssertEqual(r, .assigned(slot: SimSlot(1), alias: "iphone-17", isNew: false))
    }

    func testANewSimSkipsBusyPortsAndOwnedSlots() {
        var table = SimSlotTable(entries: [simA: .init(index: 1, alias: "iphone-17")])
        let r = assignSimSlot(udid: simB, name: "iPhone 17", table: &table, inUse: [],
                              otherAliases: [], isPortFree: { $0 != 8202 }, now: now)
        XCTAssertEqual(r, .assigned(slot: SimSlot(3), alias: "iphone-17-2", isNew: true))
    }

    func testFullTableReclaimsTheLongestUnusedSimNotEnabledNow() {
        var table = SimSlotTable()
        for i in 1...2 {
            table.entries["SIM-\(i)"] = .init(index: i, alias: "s\(i)",
                                              lastSeen: Date(timeIntervalSince1970: Double(i)))
        }
        let r = assignSimSlot(udid: simC, name: "iPhone 17", table: &table, inUse: [1],
                              otherAliases: [], isPortFree: allFree, now: now, maxSims: 2)
        XCTAssertEqual(r, .assigned(slot: SimSlot(2), alias: "iphone-17", isNew: true))
        XCTAssertNil(table.entries["SIM-2"])
        XCTAssertEqual(assignSimSlot(udid: simA, name: "x", table: &table, inUse: [1, 2],
                                     otherAliases: [], isPortFree: allFree, now: now, maxSims: 2),
                       .full)
    }

    func testAliasAvoidsPhonesAndOtherSims() {
        var table = SimSlotTable()
        let r = assignSimSlot(udid: simA, name: "Ops", table: &table, inUse: [],
                              otherAliases: ["OPS"], isPortFree: allFree, now: now)
        XCTAssertEqual(r, .assigned(slot: SimSlot(1), alias: "ops-2", isNew: true))
    }
}

final class SimAliasTests: XCTestCase {
    func testSlugs() {
        XCTAssertEqual(slugifySimName("iPhone 17 Pro Max"), "iphone-17-pro-max")
        XCTAssertEqual(slugifySimName("  iPhone SE (3rd generation) "), "iphone-se-3rd-generation")
        XCTAssertEqual(slugifySimName("iPad Pro 13-inch (M4)"), "ipad-pro-13-inch-m4")
        XCTAssertEqual(slugifySimName("17 Pro"), "pro")               // must start with a letter
    }

    func testUnusableNamesFallBack() {
        XCTAssertNil(slugifySimName(""))
        XCTAssertNil(slugifySimName("2024"))
        XCTAssertNil(slugifySimName("Cafe Bead"))                    // all hex: reads as a UDID
        XCTAssertNil(slugifySimName("Phone2"))                       // the phones' names
        XCTAssertEqual(slugifySimName("Phone 2"), "phone-2")          // not one of them
        XCTAssertEqual(simAlias(name: "Phone2", index: 3, taken: []), "sim3")
        XCTAssertEqual(simAlias(name: "", index: 1, taken: ["sim1"]), "sim1-2")
    }

    func testLongNamesStayWithinTheAliasLimitWhenMadeUnique() {
        let name = "iPhone 17 Pro Max Extra Long Test Device"
        let base = slugifySimName(name)!
        XCTAssertEqual(base, "iphone-17-pro-max-extra")             // 24 chars, trailing dash trimmed
        let second = simAlias(name: name, index: 2, taken: [base])
        XCTAssertLessThanOrEqual(second.count, 24)
        XCTAssertTrue(second.hasSuffix("-2"))
        XCTAssertFalse(second.contains("--"))
    }

    /// Whatever the name, the alias is one agents can type and a phone rename
    /// would accept.
    func testEveryAliasPassesTheAliasRules() {
        let names = ["iPhone 17 Pro", "", "1234", "Phone 1", "ÜberPhone ✨", "a", "dead beef",
                     "iPad mini (A17 Pro)", String(repeating: "x", count: 60)]
        var taken: Set<String> = []
        for (i, name) in names.enumerated() {
            let a = simAlias(name: name, index: i + 1, taken: taken)
            XCTAssertNil(validateAlias(a, forUDID: "u\(i)", in: SlotTable()), "\(name) → \(a)")
            XCTAssertFalse(taken.contains(a))
            taken.insert(a)
        }
    }
}

final class EnabledSimulatorsTests: XCTestCase {
    func testNormalizesWhatDefaultsWriteProduces() {
        let raw: [Any] = [simA.lowercased(), " \(simB) ", simA, "not-a-udid", 42, simC]
        XCTAssertEqual(normalizeEnabledSimulators(raw), [simA, simB, simC])
    }

    func testAcceptsALoneStringAndIgnoresJunk() {
        XCTAssertEqual(normalizeEnabledSimulators(simA), [simA])
        XCTAssertEqual(normalizeEnabledSimulators(nil), [])
        XCTAssertEqual(normalizeEnabledSimulators(["phone1": 1]), [])
    }

    func testPhoneUDIDsAreNotSimulatorUDIDs() {
        XCTAssertFalse(isSimulatorUDID("00008140-0006423002D3401C"))
        XCTAssertTrue(isSimulatorUDID(simA))
    }
}

final class SimRegistryEntryTests: XCTestCase {
    func testReadySimMatchesTheSharedGoldenEntryShape() throws {
        let e = simRegistryEntry(udid: simA, alias: "sim", name: "iPhone 17 Pro", runtime: "iOS 26.0",
                                 slot: SimSlot(1), phase: .ready)
        // Same as the simulator in mcp-server/testdata/devices.sample.json.
        XCTAssertEqual(e, RegisteredDevice(udid: simA, alias: "sim", kind: .simulator,
                                           productType: "iPhone 17 Pro", iosVersion: "26.0",
                                           wdaURL: "http://127.0.0.1:8201", state: .ready))
    }

    func testPhasesMapToRegistryStates() {
        func entry(_ p: SimPhase) -> RegisteredDevice {
            simRegistryEntry(udid: simB, alias: "iphone-16e", name: nil, runtime: nil,
                             slot: SimSlot(2), phase: p)
        }
        XCTAssertEqual(entry(.building).state, .starting)
        XCTAssertEqual(entry(.building).detail, "building WebDriverAgent")
        XCTAssertEqual(entry(.restarting).state, .starting)
        XCTAssertEqual(entry(.failed("Requires Xcode.")).state, .failed)
        XCTAssertEqual(entry(.failed("Requires Xcode.")).detail, "Requires Xcode.")
        XCTAssertEqual(entry(.ready).wdaURL, "http://127.0.0.1:8202")
        XCTAssertNil(entry(.ready).iosVersion)
        XCTAssertNil(entry(.ready).slot)       // `slot` is the phones' port slot
    }

    func testSeveralSimsEncodeIntoOneDeviceFile() throws {
        let file = DeviceRegistryFile(
            ownerPid: 1, appVersion: "t", updatedAt: "t", goios: nil,
            devices: [
                simRegistryEntry(udid: simA, alias: "iphone-17", name: "iPhone 17", runtime: "iOS 26.1",
                                 slot: SimSlot(1), phase: .ready),
                simRegistryEntry(udid: simB, alias: "iphone-16e", name: "iPhone 16e", runtime: "iOS 26.1",
                                 slot: SimSlot(2), phase: .starting),
            ])
        let decoded = try DeviceRegistryCodec.decode(try DeviceRegistryCodec.encode(file))
        XCTAssertEqual(decoded.devices.map(\.wdaURL), ["http://127.0.0.1:8201", "http://127.0.0.1:8202"])
        XCTAssertEqual(decoded.devices.map(\.kind), [.simulator, .simulator])
    }
}
