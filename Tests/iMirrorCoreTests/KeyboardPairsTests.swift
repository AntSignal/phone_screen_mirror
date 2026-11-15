import XCTest
@testable import iMirrorCore

final class KeyboardPairsTests: XCTestCase {
    private let phone1 = "00008150-001928E01404401C"
    private let phone2 = "00008140-000A1C2E3C80801C"
    private let cA = "6F1C9A2B-1111-4E5D-9C3B-0A1B2C3D4E5F"
    private let cB = "0B7D2E4F-2222-4A6B-8C9D-1E2F3A4B5C6D"
    private let t0 = Date(timeIntervalSince1970: 1_794_564_000)

    func testRoundTripsThroughTheFileFormat() {
        var p = KeyboardPairs()
        XCTAssertTrue(p.record(udid: phone1, central: cA.lowercased(), at: t0))
        let data = p.encode()
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: [String: String]]
        XCTAssertEqual(obj[phone1]?["central"], cA)
        XCTAssertEqual(obj[phone1]?["paired_at"], "2026-11-13T10:00:00.000Z")
        XCTAssertEqual(KeyboardPairs.decode(data), p)
    }

    func testBrokenFileIsEmptyAndBadEntriesAreDropped() {
        XCTAssertEqual(KeyboardPairs.decode(nil), KeyboardPairs())
        XCTAssertEqual(KeyboardPairs.decode(Data("{\"x".utf8)), KeyboardPairs())
        let body: [String: Any] = [
            phone1: ["central": cA, "paired_at": "2026-11-13T10:00:00Z"],
            phone2: ["central": "not-a-uuid", "paired_at": "2026-11-13T10:00:00Z"],
            "../escape": ["central": cB, "paired_at": "2026-11-13T10:00:00Z"],
            "NOTIME": ["central": cB],
        ]
        let p = KeyboardPairs.decode(try! JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(Array(p.byUDID.keys), [phone1])
    }

    func testLookupBothWaysAndForget() {
        var p = KeyboardPairs()
        p.record(udid: phone1, central: cA, at: t0)
        XCTAssertEqual(p.central(for: phone1), cA)
        XCTAssertNil(p.central(for: phone2))
        XCTAssertEqual(p.udid(forCentral: cA.lowercased()), phone1)
        XCTAssertNil(p.udid(forCentral: cB))
        p.forget(udid: phone1)
        XCTAssertNil(p.central(for: phone1))
        p.forget(udid: phone2)   // unknown UDID: no-op
        XCTAssertEqual(p, KeyboardPairs())
    }

    func testACentralBelongsToOnePhoneOnly() {
        var p = KeyboardPairs()
        p.record(udid: phone1, central: cA, at: t0)
        p.record(udid: phone2, central: cA, at: t0)
        XCTAssertNil(p.central(for: phone1))
        XCTAssertEqual(p.udid(forCentral: cA), phone2)
    }

    // MARK: - Transports

    private let slot1 = "00008150001928e01404401c"
    private let peerA = "4a:3b:2c:1d:0e:ff"

    func testAnEntryWithNoTransportIsCoreBluetooth() {
        let body: [String: Any] = [phone1: ["central": cA, "paired_at": "2026-11-13T10:00:00Z"]]
        let p = KeyboardPairs.decode(try! JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(p.pair(for: phone1)?.transport, .corebluetooth)
        XCTAssertEqual(p.central(for: phone1), cA)
        let obj = try! JSONSerialization.jsonObject(with: p.encode()) as! [String: [String: String]]
        XCTAssertEqual(obj[phone1]?["transport"], "corebluetooth")
    }

    func testDongleEntryRoundTrips() {
        var p = KeyboardPairs()
        XCTAssertTrue(p.record(udid: phone1, slot: slot1, peer: peerA.uppercased(), at: t0))
        let obj = try! JSONSerialization.jsonObject(with: p.encode()) as! [String: [String: String]]
        XCTAssertEqual(obj[phone1], ["transport": "dongle", "slot": slot1, "peer": peerA,
                                     "paired_at": "2026-11-13T10:00:00.000Z"])
        let back = KeyboardPairs.decode(p.encode())
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.pair(for: phone1), KeyboardPair(slot: slot1, peer: peerA, pairedAt: t0))
        XCTAssertNil(back.central(for: phone1))
    }

    func testBadDongleEntriesAndUnknownTransportsAreDropped() {
        let at = "2026-11-13T10:00:00Z"
        let body: [String: Any] = [
            phone1: ["transport": "dongle", "slot": "BAD SLOT", "peer": peerA, "paired_at": at],
            phone2: ["transport": "dongle", "slot": slot1, "paired_at": at],
            "00008101-AAAA": ["transport": "usb-hid", "central": cA, "paired_at": at],
            "00008101-BBBB": ["transport": "dongle", "slot": slot1, "peer": peerA, "paired_at": at],
        ]
        let p = KeyboardPairs.decode(try! JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(Array(p.byUDID.keys), ["00008101-BBBB"])
    }

    func testASlotOrPeerBelongsToOnePhoneOnly() {
        var p = KeyboardPairs()
        p.record(udid: phone1, slot: slot1, peer: peerA, at: t0)
        p.record(udid: phone2, slot: "other", peer: peerA, at: t0)
        XCTAssertNil(p.pair(for: phone1))
        p.record(udid: phone1, slot: "other", peer: "01:02:03:04:05:06", at: t0)
        XCTAssertNil(p.pair(for: phone2))
        XCTAssertFalse(p.record(udid: phone2, slot: slot1, peer: "nope", at: t0))
    }

    func testRepairingSwitchesTransport() {
        var p = KeyboardPairs()
        p.record(udid: phone1, central: cA, at: t0)
        p.record(udid: phone1, slot: slot1, peer: peerA, at: t0)
        XCTAssertEqual(p.pair(for: phone1)?.transport, .dongle)
        XCTAssertNil(p.udid(forCentral: cA))
    }

    // MARK: - Pairing rule

    private func window(before: Set<String> = []) -> PairingWindow {
        PairingWindow(udid: phone1, opensAt: t0, closesAt: t0.addingTimeInterval(120), subscribedBefore: before)
    }

    func testExactlyOneNewCentralPairs() {
        let out = PairingRule.decide(window: window(), subscriptions: [(cA.lowercased(), t0.addingTimeInterval(5)),
                                                                       (cA, t0.addingTimeInterval(9))],
                                     pairs: KeyboardPairs())
        XCTAssertEqual(out, .paired(central: cA))
    }

    func testTwoNewCentralsAreAmbiguous() {
        let out = PairingRule.decide(window: window(), subscriptions: [(cA, t0.addingTimeInterval(5)),
                                                                       (cB, t0.addingTimeInterval(6))],
                                     pairs: KeyboardPairs())
        XCTAssertEqual(out, .ambiguous(count: 2))
    }

    func testNothingInTheWindowIsNone() {
        let out = PairingRule.decide(window: window(), subscriptions: [(cA, t0.addingTimeInterval(-1)),
                                                                       (cB, t0.addingTimeInterval(120))],
                                     pairs: KeyboardPairs())
        XCTAssertEqual(out, .none)
    }

    func testAnotherPhonesCentralIsNotNew() {
        var pairs = KeyboardPairs()
        pairs.record(udid: phone2, central: cB, at: t0)
        let out = PairingRule.decide(window: window(), subscriptions: [(cA, t0.addingTimeInterval(5)),
                                                                       (cB, t0.addingTimeInterval(6))],
                                     pairs: pairs)
        XCTAssertEqual(out, .paired(central: cA))
    }

    func testAlreadySubscribedCentralIsNotNew() {
        let out = PairingRule.decide(window: window(before: [cB.lowercased()]),
                                     subscriptions: [(cB, t0.addingTimeInterval(6))], pairs: KeyboardPairs())
        XCTAssertEqual(out, .none)
    }

    func testRepairingTheSamePhoneKeepsItsCentral() {
        var pairs = KeyboardPairs()
        pairs.record(udid: phone1, central: cA, at: t0)
        let out = PairingRule.decide(window: window(), subscriptions: [(cA, t0.addingTimeInterval(5))], pairs: pairs)
        XCTAssertEqual(out, .paired(central: cA))
    }

    func testJunkCentralIdsAreIgnored() {
        let out = PairingRule.decide(window: window(), subscriptions: [("nope", t0.addingTimeInterval(5))],
                                     pairs: KeyboardPairs())
        XCTAssertEqual(out, .none)
    }
}
