import XCTest
@testable import iMirrorCore

/// Which runner-install events a chain lets through (InstallEventGate).
final class InstallEventGateTests: XCTestCase {
    func testAReplacedBringUpsEventsAreDropped() {
        var gate = InstallEventGate()
        XCTAssertTrue(gate.pass(.checking, from: 2, current: 2))
        XCTAssertFalse(gate.pass(.done(.failed(.other(raw: "x"))), from: 1, current: 2))
        XCTAssertFalse(gate.pass(.installing, from: 1, current: 2))
        XCTAssertFalse(gate.installShowing)
    }

    /// The UI saw "Installing…"; the chain restarted before the install
    /// ended. Without `.abandoned` the phone would say installing for good.
    func testAnInstallTheUISawStartIsReportedAbandoned() {
        var gate = InstallEventGate()
        XCTAssertTrue(gate.pass(.installing, from: 1, current: 1))
        XCTAssertTrue(gate.superseded())
        XCTAssertFalse(gate.superseded(), "reported once")
        XCTAssertTrue(gate.pass(.upgrading(from: "9.9.0", to: "16.14.2"), from: 2, current: 2))
        XCTAssertTrue(gate.pass(.upgradeFailed(kept: "9.9.0", raw: "x"), from: 2, current: 2))
        XCTAssertTrue(gate.installShowing)
        XCTAssertTrue(gate.pass(.done(.alreadyPresent), from: 2, current: 2))
        XCTAssertFalse(gate.superseded(), "a finished install is not abandoned")
    }

    func testACheckAloneIsNeverAbandoned() {
        var gate = InstallEventGate()
        XCTAssertTrue(gate.pass(.checking, from: 1, current: 1))
        XCTAssertFalse(gate.superseded())
    }
}
