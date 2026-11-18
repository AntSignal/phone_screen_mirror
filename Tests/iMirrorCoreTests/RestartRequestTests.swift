import XCTest
@testable import iMirrorCore

final class RestartRequestFileTests: XCTestCase {
    private let udid = "00008150-001928E01404401C"

    private func body(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    func testReadsAWellFormedRequest() {
        let data = body(["udid": udid, "requested_at": "2026-11-13T10:00:00.250Z", "requested_by": "imirror-ctl"])
        guard case .request(let r) = RestartRequestFile.read(fileName: "restart-\(udid).json", data: data) else {
            return XCTFail("not read")
        }
        XCTAssertEqual(r.udid, udid)
        XCTAssertEqual(r.requestedBy, "imirror-ctl")
        XCTAssertEqual(r.requestedAt.timeIntervalSince1970, 1_794_564_000.25, accuracy: 0.001)
    }

    func testTempAndForeignFilesAreNotOurs() {
        for name in ["restart-\(udid).json.123.tmp", "notes.txt", "restart-.json", "restart-../x.json"] {
            XCTAssertEqual(RestartRequestFile.read(fileName: name, data: nil), .notOurs, name)
        }
    }

    func testABodyForAnotherPhoneIsRefused() {
        let data = body(["udid": "OTHER-UDID", "requested_at": "2026-11-13T10:00:00Z"])
        XCTAssertEqual(RestartRequestFile.read(fileName: "restart-\(udid).json", data: data), .unreadable)
    }

    func testMissingTimestampOrJunkIsUnreadable() {
        XCTAssertEqual(RestartRequestFile.read(fileName: "restart-\(udid).json", data: body(["udid": udid])),
                       .unreadable)
        XCTAssertEqual(RestartRequestFile.read(fileName: "restart-\(udid).json", data: Data("{\"ud".utf8)),
                       .unreadable)
    }

    func testRequesterIsClippedToOneShortLine() {
        let data = body(["udid": udid, "requested_at": "2026-11-13T10:00:00Z",
                         "requested_by": "a\nb" + String(repeating: "x", count: 200)])
        guard case .request(let r) = RestartRequestFile.read(fileName: "restart-\(udid).json", data: data) else {
            return XCTFail("not read")
        }
        XCTAssertFalse(r.requestedBy.contains("\n"))
        XCTAssertEqual(r.requestedBy.count, 64)
    }
}

final class RestartRequestGateTests: XCTestCase {
    private let wall = Date(timeIntervalSince1970: 1_794_564_000)

    private func req(_ udid: String = "U1", ageSec: TimeInterval = 1) -> RestartRequest {
        RestartRequest(udid: udid, requestedAt: wall.addingTimeInterval(-ageSec), requestedBy: "t")
    }

    func testFirstRequestIsAccepted() {
        var g = RestartRequestGate()
        XCTAssertEqual(g.decide(req(), attached: true, wallNow: wall, uptime: 1000), .accepted)
    }

    func testASecondRequestWithinAMinuteIsCooldown() {
        var g = RestartRequestGate()
        _ = g.decide(req(), attached: true, wallNow: wall, uptime: 1000)
        XCTAssertEqual(g.decide(req(), attached: true, wallNow: wall, uptime: 1059), .cooldown)
        XCTAssertEqual(g.decide(req(), attached: true, wallNow: wall, uptime: 1060), .accepted)
    }

    func testCooldownDoesNotRestartTheClock() {
        var g = RestartRequestGate()
        _ = g.decide(req(), attached: true, wallNow: wall, uptime: 1000)
        _ = g.decide(req(), attached: true, wallNow: wall, uptime: 1050)
        XCTAssertEqual(g.decide(req(), attached: true, wallNow: wall, uptime: 1061), .accepted)
    }

    func testCooldownIsPerPhone() {
        var g = RestartRequestGate()
        _ = g.decide(req("U1"), attached: true, wallNow: wall, uptime: 1000)
        XCTAssertEqual(g.decide(req("U2"), attached: true, wallNow: wall, uptime: 1001), .accepted)
    }

    func testOldOrFutureRequestsAreStaleAndDontStartTheClock() {
        var g = RestartRequestGate()
        XCTAssertEqual(g.decide(req(ageSec: 121), attached: true, wallNow: wall, uptime: 1000), .stale)
        XCTAssertEqual(g.decide(req(ageSec: -121), attached: true, wallNow: wall, uptime: 1000), .stale)
        XCTAssertEqual(g.decide(req(), attached: true, wallNow: wall, uptime: 1001), .accepted)
    }

    func testAPhoneWithoutAChainIsNotAttached() {
        var g = RestartRequestGate()
        XCTAssertEqual(g.decide(req(), attached: false, wallNow: wall, uptime: 1000), .notAttached)
        XCTAssertTrue(g.lastHonoured.isEmpty)
    }
}
