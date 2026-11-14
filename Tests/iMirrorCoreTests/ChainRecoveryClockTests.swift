// Upstream's ChainRecoveryClockTests (fed3fb9), ported onto our per-phone
// ChainLadderState: each restart the ladder asks for gets its own full
// grace, counted from the restart, not from the start of the outage.

import XCTest
@testable import iMirrorCore

final class ChainRecoveryClockTests: XCTestCase {
    /// The restarted chain needs ~4 s to settle before runwda spawns. The
    /// 3 s probe used to find stage 1's grace already spent and give up.
    func testInitialBootRestartSurvivesTheNextProbeTick() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        XCTAssertEqual(ladder.tick(now: 90, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        XCTAssertEqual(ladder.tick(now: 93, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 96, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertFalse(ladder.hardStopped)
    }

    /// Same for the shared tunnel: a tunnel restart used to be followed,
    /// one probe later, by a give-up.
    func testATunnelRestartGetsItsOwnGraceToo() {
        var ladder = ChainLadderState()
        ladder.onConnected()
        ladder.onDown(now: 0)
        XCTAssertEqual(ladder.tick(now: 30, othersHealthy: false, tunnelHasDevice: true), .restartDeviceChain)
        ladder.onRunwdaStarted(now: 40)
        XCTAssertEqual(ladder.tick(now: 130, othersHealthy: false, tunnelHasDevice: true), .restartTunnelAndChains)
        XCTAssertEqual(ladder.tick(now: 133, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 219, othersHealthy: false, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 220, othersHealthy: false, tunnelHasDevice: true), .giveUp)
    }

    func testPreparationAndRunwdaEachReceiveFullGraceWithoutAnotherRestart() {
        var ladder = ChainLadderState()
        ladder.onConnected()
        ladder.onDown(now: 0)
        XCTAssertEqual(ladder.tick(now: 30, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        XCTAssertEqual(ladder.tick(now: 100, othersHealthy: true, tunnelHasDevice: true), .wait)
        ladder.onRunwdaStarted(now: 110)
        XCTAssertEqual(ladder.tick(now: 199, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 200, othersHealthy: true, tunnelHasDevice: true), .giveUp)
    }

    /// The fresh budget is a deadline, not a pause: a restart that never
    /// gets as far as runwda still moves on.
    func testRestartThatNeverLaunchesRunwdaStillExpires() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        XCTAssertEqual(ladder.tick(now: 90, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        XCTAssertEqual(ladder.tick(now: 179, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 180, othersHealthy: true, tunnelHasDevice: true), .giveUp)
    }

    func testRepeatedDownProbesCannotPostponeRecovery() {
        var ladder = ChainLadderState()
        ladder.onConnected()
        ladder.onDown(now: 10)
        ladder.onDown(now: 39)
        XCTAssertEqual(ladder.tick(now: 40, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        ladder.reset()
        XCTAssertEqual(ladder.stage, 0)
        XCTAssertEqual(ladder.tick(now: 200, othersHealthy: true, tunnelHasDevice: true), .wait)
    }

    /// A USB-reset restart after a long passcode hold: the hold froze the
    /// climb, not the clock, so the restart used to escalate on the next probe.
    func testAnOutsideRestartAfterALongHoldStartsAFreshClock() {
        var ladder = ChainLadderState()
        ladder.onConnected()
        ladder.onDown(now: 0)
        XCTAssertEqual(ladder.tick(now: 1_000, othersHealthy: true, tunnelHasDevice: true, held: true), .wait)
        ladder.noteOutsideRestart(now: 1_000)
        XCTAssertEqual(ladder.tick(now: 1_003, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.wedgeSince, 1_000)
        XCTAssertEqual(ladder.stage, 1)
    }
}
