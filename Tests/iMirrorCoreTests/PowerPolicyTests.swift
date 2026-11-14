import XCTest
@testable import iMirrorCore

final class RelayTrafficMeterTests: XCTestCase {
    func testOnlyOurOwnProbesIsNoTraffic() {
        var m = RelayTrafficMeter()
        m.sample(relayRequests: 10, ownRequests: 10, now: 100)
        m.sample(relayRequests: 20, ownRequests: 20, now: 130)
        XCTAssertNil(m.lastTrafficAt)
    }

    func testAClientRequestIsTraffic() {
        var m = RelayTrafficMeter()
        m.sample(relayRequests: 10, ownRequests: 10, now: 100)
        m.sample(relayRequests: 12, ownRequests: 11, now: 115)
        XCTAssertEqual(m.lastTrafficAt, 115)
    }

    func testAProbeTheRelayHasNotSeenYetIsNoTraffic() {
        // Ours, counted before the relay saw it.
        var m = RelayTrafficMeter()
        m.sample(relayRequests: 10, ownRequests: 10, now: 100)
        m.sample(relayRequests: 10, ownRequests: 11, now: 115)
        m.sample(relayRequests: 11, ownRequests: 11, now: 130)
        XCTAssertNil(m.lastTrafficAt)
    }

    func testOldTrafficKeepsItsTime() {
        var m = RelayTrafficMeter()
        m.sample(relayRequests: 5, ownRequests: 0, now: 100)
        m.sample(relayRequests: 15, ownRequests: 10, now: 200)
        XCTAssertEqual(m.lastTrafficAt, 100)
    }
}

final class SleepPolicyTests: XCTestCase {
    func testNothingHeldWithAutomationOff() {
        XCTAssertFalse(SleepPolicy.keepAwake(automationOn: false, lastTrafficAt: 100, recovering: true, now: 100))
    }

    func testRecentTrafficHolds() {
        XCTAssertTrue(SleepPolicy.keepAwake(automationOn: true, lastTrafficAt: 100, recovering: false, now: 400))
        XCTAssertFalse(SleepPolicy.keepAwake(automationOn: true, lastTrafficAt: 100, recovering: false, now: 401))
    }

    func testIdleWithoutRecoveryReleases() {
        XCTAssertFalse(SleepPolicy.keepAwake(automationOn: true, lastTrafficAt: nil, recovering: false, now: 1))
    }

    func testRecoveryHoldsWithoutTraffic() {
        XCTAssertTrue(SleepPolicy.keepAwake(automationOn: true, lastTrafficAt: nil, recovering: true, now: 1))
    }

    func testWhichReasonsAreRecovery() {
        XCTAssertFalse(SleepPolicy.isRecovering(nil))
        XCTAssertFalse(SleepPolicy.isRecovering(.gaveUp))
        XCTAssertFalse(SleepPolicy.isRecovering(.macAsleep))
        for r in [DeviceReason.usbReset, .recovering, .booting, .wdaWedged, .needsPasscode] {
            XCTAssertTrue(SleepPolicy.isRecovering(r), r.rawValue)
        }
    }
}

final class InFlightRequestCountTests: XCTestCase {
    func testStartedCountsEachRequestOnce() {
        var r = InFlightRequests()
        r.clientSent(1); r.clientSent(1)      // one body in two chunks
        r.backendSent(1)
        r.clientSent(1)                       // keep-alive: a second request
        r.clientSent(2)
        XCTAssertEqual(r.started, 3)
    }
}
