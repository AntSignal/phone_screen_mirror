import XCTest
@testable import iMirrorCore

/// One phone missing from the shared tunnel used to restart the tunnel, and
/// so every phone's chain, at its first grace. These pin the new rule: with
/// other phones up it restarts only its own chain until three of those fail.
final class TunnelEscalationTests: XCTestCase {
    /// A phone that worked, then lost its tunnel route at `t`.
    private func wedged(at t: TimeInterval) -> ChainLadderState {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: t - 100)
        ladder.onConnected(now: t - 90)
        ladder.onDown(now: t)
        return ladder
    }

    /// Ticks until the stage's grace runs out; returns the action.
    private func climb(_ ladder: inout ChainLadderState, from t: TimeInterval, othersHealthy: Bool = true,
                       tunnelHasDevice: Bool = false) -> (DeviceRecoveryAction, TimeInterval) {
        var now = t
        while now < t + 1_000 {
            now += 3
            let a = ladder.tick(now: now, othersHealthy: othersHealthy, tunnelHasDevice: tunnelHasDevice)
            if a != .wait { return (a, now) }
        }
        return (.wait, now)
    }

    func testWithNoOtherPhoneUpTheTunnelGoesFirstAsBefore() {
        var ladder = wedged(at: 1_000)
        XCTAssertEqual(ladder.tick(now: 1_030, othersHealthy: false, tunnelHasDevice: false), .restartTunnelAndChains)
        XCTAssertEqual(ladder.stage, 2)
        XCTAssertFalse(ladder.escalation.tunnelSpent)
    }

    func testWithOthersUpItRestartsItsOwnChainThreeTimesThenTheTunnel() {
        var ladder = wedged(at: 1_000)
        var t: TimeInterval = 1_000
        for n in 0..<3 {
            let (a, at) = climb(&ladder, from: t)
            XCTAssertEqual(a, .restartDeviceChain, "own restart \(n + 1)")
            XCTAssertEqual(ladder.stage, 1)
            XCTAssertEqual(ladder.escalation.failures.count, n)
            ladder.onRunwdaStarted(now: at + 30)
            t = at + 30
        }
        let (a, at) = climb(&ladder, from: t)
        XCTAssertEqual(a, .restartTunnelAndChains)
        XCTAssertTrue(ladder.escalation.tunnelSpent)
        XCTAssertEqual(ladder.escalation.failures, [])
        ladder.onRunwdaStarted(now: at + 30)
        XCTAssertEqual(climb(&ladder, from: at + 30).0, .giveUp)
    }

    /// Each attempt here takes 200 s, so three never fit in 5 min. A
    /// continuous outage must still reach the tunnel, not loop forever.
    func testASlowOutageStillEscalates() {
        var ladder = wedged(at: 0)
        var t: TimeInterval = 0
        var actions: [DeviceRecoveryAction] = []
        for _ in 0..<4 {
            let (a, at) = climb(&ladder, from: t)
            actions.append(a)
            ladder.onRunwdaStarted(now: at + 110)
            t = at + 110
        }
        XCTAssertEqual(actions, [.restartDeviceChain, .restartDeviceChain, .restartDeviceChain, .restartTunnelAndChains])
    }

    func testATunnelThatListsThePhoneNeverCountsAgainstIt() {
        var ladder = wedged(at: 1_000)
        let (a, at) = climb(&ladder, from: 1_000, tunnelHasDevice: true)
        XCTAssertEqual(a, .restartDeviceChain)
        ladder.onRunwdaStarted(now: at)
        XCTAssertEqual(climb(&ladder, from: at, tunnelHasDevice: true).0, .giveUp)
        XCTAssertFalse(ladder.escalation.tunnelSpent)
    }

    /// The old bug: a flap reset giveUps on each connect, so every outage
    /// could restart the tunnel again. A brief reconnect keeps the count.
    func testAFlapDoesNotResetTheCount() {
        var ladder = wedged(at: 1_000)
        var t: TimeInterval = 1_000
        var actions: [DeviceRecoveryAction] = []
        for _ in 0..<4 {
            let (a, at) = climb(&ladder, from: t)
            actions.append(a)
            // Comes back for 20 s, then drops again.
            ladder.onRunwdaStarted(now: at + 10)
            ladder.onConnected(now: at + 40)
            ladder.onConnected(now: at + 60)
            ladder.onDown(now: at + 60)
            t = at + 60
        }
        XCTAssertEqual(actions, [.restartDeviceChain, .restartDeviceChain, .restartDeviceChain, .restartTunnelAndChains])
    }

    /// Once it has cost the others a tunnel restart, a flapping phone may
    /// not do it again until it has been healthy for 10 minutes.
    func testOneTunnelRestartPerSettle() {
        var ladder = wedged(at: 0)
        var t: TimeInterval = 0
        func flapCycle() -> DeviceRecoveryAction {
            let (a, at) = climb(&ladder, from: t)
            ladder.onRunwdaStarted(now: at + 10)
            ladder.onConnected(now: at + 40)
            ladder.onDown(now: at + 60)
            t = at + 60
            return a
        }
        let first = (0..<4).map { _ in flapCycle() }
        XCTAssertEqual(first.last, .restartTunnelAndChains)
        let second = (0..<4).map { _ in flapCycle() }
        XCTAssertEqual(second, [.restartDeviceChain, .restartDeviceChain, .restartDeviceChain, .giveUp])
    }

    func testTenMinutesOfHealthClearsEverything() {
        var e = TunnelEscalation()
        e.ownChainRestarted()
        e.restartDecided(now: 100)
        e.tunnelRestarted(costOthers: true)
        e.ownChainRestarted()
        e.connected(now: 200)
        e.connected(now: 799)
        XCTAssertTrue(e.tunnelSpent)
        XCTAssertTrue(e.pending)
        e.connected(now: 800)
        XCTAssertFalse(e.tunnelSpent)
        XCTAssertFalse(e.pending)
        XCTAssertEqual(e.upSince, 200)
    }

    func testAReconnectForgetsOnlyFailuresOlderThanTheWindow() {
        var e = TunnelEscalation()
        e.restartDecided(now: 0)
        XCTAssertEqual(e.failures, [])   // nothing was pending yet
        for t in [200.0, 250, 500] { e.ownChainRestarted(); e.restartDecided(now: t) }
        XCTAssertEqual(e.failures, [200, 250, 500])
        e.connected(now: 520)
        XCTAssertEqual(e.failures, [250, 500])
        // Already up: no more pruning until the next reconnect.
        e.connected(now: 900)
        XCTAssertEqual(e.failures, [250, 500])
    }

    func testChooseNeedsThreeFailures() {
        var e = TunnelEscalation()
        XCTAssertEqual(e.choose(), .ownChain)
        for t in [1.0, 2, 3] { e.ownChainRestarted(); e.restartDecided(now: t) }
        XCTAssertEqual(e.failures.count, 3)
        XCTAssertEqual(e.choose(), .tunnel)
        e.tunnelRestarted(costOthers: false)
        XCTAssertFalse(e.tunnelSpent)   // nobody else paid for it
    }

    func testAutomationResetClearsTheEscalation() {
        var ladder = wedged(at: 0)
        _ = climb(&ladder, from: 0)
        XCTAssertTrue(ladder.escalation.pending)
        ladder.reset()
        XCTAssertEqual(ladder.escalation, TunnelEscalation())
    }
}
