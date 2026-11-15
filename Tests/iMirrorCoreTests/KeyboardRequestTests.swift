import XCTest
@testable import iMirrorCore

final class KeyboardRequestFileTests: XCTestCase {
    private let udid = "00008140-0006423002D3401C"
    private var fileName: String { "keyboard-\(udid).json" }
    private let at = "2026-11-14T10:00:00.000Z"

    private func read(_ obj: [String: Any]) -> KeyboardRequestFile.Read {
        KeyboardRequestFile.read(fileName: fileName, data: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func base(_ action: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["udid": udid, "requested_at": at, "requested_by": "imirror-ctl", "action": action].merging(extra) { _, b in b }
    }

    func testReadsEachAction() {
        for action in ["pair", "forget"] {
            guard case .request(let r) = read(base(action)) else { return XCTFail(action) }
            XCTAssertEqual(r.action.rawValue, action)
            XCTAssertNil(r.text)
            XCTAssertEqual(r.requestedBy, "imirror-ctl")
        }
        guard case .request(let r) = read(base("test", ["text": "hello 123"])) else { return XCTFail("test") }
        XCTAssertEqual(r.action, .test)
        XCTAssertEqual(r.text, "hello 123")
    }

    func testOtherNamesAreNotOurs() {
        for n in ["keyboard-\(udid).json.9.tmp", "restart-\(udid).json", "keyboard-.json", "keyboard-../x.json"] {
            XCTAssertEqual(KeyboardRequestFile.read(fileName: n, data: nil), .notOurs, n)
        }
    }

    func testAnotherPhonesBodyOrJunkIsUnreadable() {
        XCTAssertEqual(read(["udid": "00008150-001928E01404401C", "requested_at": at, "action": "pair"]), .unreadable)
        XCTAssertEqual(read(["udid": udid, "action": "pair"]), .unreadable)
        XCTAssertEqual(KeyboardRequestFile.read(fileName: fileName, data: Data("{\"ud".utf8)), .unreadable)
    }

    func testUnknownOrMissingActionIsRefused() {
        XCTAssertEqual(read(base("passcode")), .refused(udid: udid, .unknownAction))
        XCTAssertEqual(read(base("PAIR")), .refused(udid: udid, .unknownAction))
        var noAction = base("pair"); noAction["action"] = nil
        XCTAssertEqual(read(noAction), .refused(udid: udid, .unknownAction))
    }

    func testAnExtraKeyIsRefusedSoAPasscodeCantRideAlong() {
        XCTAssertEqual(read(base("test", ["text": "hello", "passcode": "123456"])), .refused(udid: udid, .badRequest))
        XCTAssertEqual(read(base("pair", ["value": "x"])), .refused(udid: udid, .badRequest))
    }

    func testTestTextMustPassTheValidatorAndHoldALetter() {
        for bad in ["", "123456", "1234", "0000 1111", "Hello", "hi!", "tab\there", String(repeating: "a", count: 33)] {
            XCTAssertEqual(read(base("test", ["text": bad])), .refused(udid: udid, .badText), bad)
        }
        XCTAssertEqual(read(base("test")), .refused(udid: udid, .badText), "test needs text")
        XCTAssertEqual(read(base("test", ["text": 42])), .refused(udid: udid, .badText))
        for good in ["a", "hello 123", "x1", "1 a 2 b 3", String(repeating: "z", count: 32)] {
            XCTAssertTrue(KeyboardRequestFile.isAllowedTestText(good), good)
        }
    }

    func testTestTextCantHoldFourDigitsAnywhere() {
        // A numeric passcode field may skip the letters and spaces.
        for bad in ["a 1234", "x123456", "1a2b3c4d", "pin 12 34", "a\u{0332}1"] {
            XCTAssertEqual(read(base("test", ["text": bad])), .refused(udid: udid, .badText), bad)
        }
    }

    func testPairAndForgetCarryNoText() {
        XCTAssertEqual(read(base("pair", ["text": "hello"])), .refused(udid: udid, .badText))
        XCTAssertEqual(read(base("forget", ["text": "hello"])), .refused(udid: udid, .badText))
    }

    func testRequesterIsClipped() {
        guard case .request(let r) = read(base("pair", ["requested_by": "a\nb" + String(repeating: "x", count: 100)]))
        else { return XCTFail("not read") }
        XCTAssertEqual(r.requestedBy.count, 64)
        XCTAssertFalse(r.requestedBy.contains("\n"))
    }
}

final class KeyboardRequestGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_650_400)

    private func req(_ action: KeyboardAction, age: TimeInterval = 1) -> KeyboardRequest {
        KeyboardRequest(udid: "U-1", requestedAt: now.addingTimeInterval(-age), requestedBy: "t", action: action,
                        text: action == .test ? "hello" : nil)
    }

    func testPairNeedsThePhoneAttached() {
        XCTAssertNil(KeyboardRequestGate.refusal(req(.pair), attached: true, paired: false, wallNow: now))
        XCTAssertEqual(KeyboardRequestGate.refusal(req(.pair), attached: false, paired: true, wallNow: now),
                       .notAttached)
    }

    func testTestNeedsAPairingButNotUSB() {
        XCTAssertNil(KeyboardRequestGate.refusal(req(.test), attached: false, paired: true, wallNow: now))
        XCTAssertEqual(KeyboardRequestGate.refusal(req(.test), attached: true, paired: false, wallNow: now),
                       .notPaired)
    }

    func testForgetAlwaysGoes() {
        XCTAssertNil(KeyboardRequestGate.refusal(req(.forget), attached: false, paired: false, wallNow: now))
    }

    func testOldOrFutureRequestsAreStale() {
        XCTAssertEqual(KeyboardRequestGate.refusal(req(.pair, age: 121), attached: true, paired: true, wallNow: now),
                       .stale)
        XCTAssertEqual(KeyboardRequestGate.refusal(req(.forget, age: -121), attached: true, paired: true, wallNow: now),
                       .stale)
        XCTAssertNil(KeyboardRequestGate.refusal(req(.pair, age: 119), attached: true, paired: true, wallNow: now))
    }
}

final class KeyboardEventTests: XCTestCase {
    func testPairingOutcomesMapToDetails() {
        XCTAssertEqual(KeyboardEventDetail(.paired(central: "C")), .paired)
        XCTAssertEqual(KeyboardEventDetail(.ambiguous(count: 2)), .ambiguous)
        XCTAssertEqual(KeyboardEventDetail(.none), .timeout)
    }

    func testTheLineCarriesACountAndNoText() throws {
        let e = DeviceEvent.keyboard(at: Date(timeIntervalSince1970: 0), udid: "U-1", alias: "phone2",
                                     .typedTest, chars: 9)
        let obj = try JSONSerialization.jsonObject(with: DeviceEventCodec.line(e)) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "keyboard")
        XCTAssertEqual(obj["detail"] as? String, "typed_test")
        XCTAssertEqual(obj["chars"] as? Int, 9)
        XCTAssertEqual(Set(obj.keys), ["ts", "udid", "alias", "event", "detail", "chars"])
    }

    func testAFailureNamesItsReason() throws {
        let e = DeviceEvent.keyboard(at: Date(), udid: "U-1", alias: "", .failed, reason: .notPaired)
        let obj = try JSONSerialization.jsonObject(with: DeviceEventCodec.line(e)) as! [String: Any]
        XCTAssertEqual(obj["reason"] as? String, "not_paired")
        XCTAssertNil(obj["chars"])
    }

    func testOtherEventsGainNoCharsKey() {
        let line = String(decoding: DeviceEventCodec.line(DeviceEvent(at: Date(), udid: "U", alias: "a", event: .wake)),
                          as: UTF8.self)
        XCTAssertFalse(line.contains("chars"))
    }
}
