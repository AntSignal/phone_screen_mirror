import XCTest
@testable import iMirrorCore

// Every branch of the auto-unlock gate. A wrong attempt counts toward the
// phone's lockout, so most of these check that the gate says no.

private let udid = "00008140-0006423002D3401C"
private let wall0 = Date(timeIntervalSince1970: 1_794_700_000)

private func on() -> AutoUnlockRecord {
    var r = AutoUnlockRecord()
    r.enable(by: .settings, at: wall0)
    return r
}

private let ok = PasscodeGateContext(enabled: true, paired: true, attached: true)

/// Wall time `t` seconds after wall0, so monotonic and wall move together.
private func w(_ t: TimeInterval) -> Date { wall0.addingTimeInterval(t) }

final class PasscodeGateDecideTests: XCTestCase {
    /// A gate whose phone has been locked since t=0 and read locked at `at`.
    private func lockedGate(_ record: AutoUnlockRecord = on(), at: TimeInterval = 30) -> PasscodeGate {
        var g = PasscodeGate(udid: udid, history: record)
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: at)
        return g
    }

    private func decide(_ g: inout PasscodeGate, _ c: PasscodeGateContext = ok, at: TimeInterval = 30.5)
        -> PasscodeGateStep { g.decide(c, now: at, wallNow: w(at)) }

    func testDisabled() {
        var g = lockedGate(AutoUnlockRecord())
        XCTAssertEqual(decide(&g), .nothing(.disabled))
        var h = lockedGate()
        var c = ok; c.enabled = false
        XCTAssertEqual(decide(&h, c), .nothing(.disabled))
    }

    func testNotPaired() {
        var g = lockedGate(); var c = ok; c.paired = false
        XCTAssertEqual(decide(&g, c), .nothing(.notPaired))
    }

    func testNotAttached() {
        var g = lockedGate(); var c = ok; c.attached = false
        XCTAssertEqual(decide(&g, c), .nothing(.notAttached))
    }

    func testMacAsleep() {
        var g = lockedGate(); var c = ok; c.macAsleep = true
        XCTAssertEqual(decide(&g, c), .nothing(.macAsleep))
    }

    func testTheSheetNeverWakesEvenWhenLocked() {
        var g = lockedGate(); var c = ok; c.sheetUp = true
        XCTAssertEqual(decide(&g, c), .nothing(.sheet))
    }

    func testWDAUp() {
        var g = lockedGate(); var c = ok; c.wdaUp = true
        XCTAssertEqual(decide(&g, c), .nothing(.wdaUp))
    }

    func testKeyboardBusy() {
        var g = lockedGate(); var c = ok; c.keyboardBusy = true
        XCTAssertEqual(decide(&g, c), .nothing(.keyboardBusy))
    }

    func testAClickBeingCheckedHolds() {
        var g = lockedGate(); var c = ok; c.clickChecking = true
        XCTAssertEqual(decide(&g, c), .nothing(.clickChecking))
    }

    func testNoReadingProbes() {
        var g = PasscodeGate(udid: udid, history: on())
        XCTAssertEqual(decide(&g), .probe)
    }

    func testTwoSecondsIsFreshAndAHairMoreIsNot() {
        var g = lockedGate()
        XCTAssertEqual(g.decide(ok, now: 32.001, wallNow: w(32)), .probe)
        var h = lockedGate()
        XCTAssertEqual(h.decide(ok, now: 32.0, wallNow: w(32)), .wake)
    }

    func testAFreshUnknownHolds() {
        var g = lockedGate()
        g.reading(.unknown, startedAt: 30.2)
        XCTAssertEqual(decide(&g), .nothing(.lockUnknown))
    }

    func testAFreshUnlockedHolds() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.unlocked, startedAt: 30)
        XCTAssertEqual(decide(&g), .nothing(.unlocked))
    }

    func testTheLockMustSettleTwentySeconds() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 10)
        g.reading(.locked, startedAt: 29.9)
        XCTAssertEqual(g.decide(ok, now: 29.9, wallNow: w(29.9)), .nothing(.settling))
        g.reading(.locked, startedAt: 30)
        XCTAssertEqual(g.decide(ok, now: 30, wallNow: w(30)), .wake)
    }

    func testOneTryPerEpisode() {
        var r = on(); r.episodeAttempted = true
        var g = lockedGate(r)
        XCTAssertEqual(decide(&g), .nothing(.triedThisEpisode))
    }

    func testTheGapIsTwoMinutes() {
        var r = on(); r.attempts = [w(30.5 - 119)]
        var g = lockedGate(r)
        XCTAssertEqual(decide(&g), .nothing(.tooSoon))
        r.attempts = [w(30.5 - 120)]
        var h = lockedGate(r)
        XCTAssertEqual(decide(&h), .wake)
    }

    func testThreeAnHourAtMost() {
        var r = on(); r.attempts = [w(30.5 - 3000), w(30.5 - 2000), w(30.5 - 1000)]
        var g = lockedGate(r)
        XCTAssertEqual(decide(&g), .nothing(.hourlyCap))
        r.attempts = [w(30.5 - 3601), w(30.5 - 2000), w(30.5 - 1000)]
        var h = lockedGate(r)
        XCTAssertEqual(decide(&h), .wake)
    }

    func testAnAttemptInTheFutureCountsAsJustNow() {
        var r = on(); r.attempts = [w(30.5 + 86_400)]
        var g = lockedGate(r)
        XCTAssertEqual(decide(&g), .nothing(.tooSoon))
    }

    func testWakeStartedSpendsTheEpisode() {
        var g = lockedGate()
        XCTAssertEqual(decide(&g), .wake)
        g.wakeStarted(now: 30.5, wallNow: w(30.5))
        XCTAssertEqual(g.record.attempts, [w(30.5)])
        XCTAssertEqual(g.record.pendingSince, w(30.5))
        XCTAssertTrue(g.record.episodeAttempted)
        XCTAssertTrue(g.inProgress)
        XCTAssertEqual(decide(&g, at: 31), .nothing(.inProgress), "nothing while the wake goes out")
    }
}

/// From the wake to the typing.
final class PasscodeGateAfterWakeTests: XCTestCase {
    /// Woken at 30.5, wake ended at 32.
    private func woken() -> PasscodeGate {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        XCTAssertEqual(g.decide(ok, now: 30.5, wallNow: w(30.5)), .wake)
        g.wakeStarted(now: 30.5, wallNow: w(30.5))
        g.wakeEnded(now: 32)
        return g
    }

    func testAReadingFromBeforeTheWakeIsNotReused() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        _ = g.decide(ok, now: 30.1, wallNow: w(30.1))
        g.wakeStarted(now: 30.1, wallNow: w(30.1))
        g.wakeEnded(now: 30.3)   // the last reading is only 0.3 s old
        XCTAssertEqual(g.decide(ok, now: 30.3, wallNow: w(30.3)), .probe)
    }

    func testLockedAfterTheWakeApprovesTyping() {
        var g = woken()
        g.reading(.locked, startedAt: 32.1)
        XCTAssertEqual(g.decide(ok, now: 32.4, wallNow: w(32.4)),
                       .type(AutoTypeApproval(udid: udid, readingStartedAt: 32.1)))
        XCTAssertEqual(g.decide(ok, now: 32.5, wallNow: w(32.5)), .nothing(.inProgress), "one approval only")
    }

    func testUnlockedAfterTheWakeTypesNothing() {
        var g = woken()
        g.reading(.unlocked, startedAt: 32.1)
        XCTAssertEqual(g.decide(ok, now: 32.4, wallNow: w(32.4)), .finished(.unlockedBeforeTyping))
        XCTAssertTrue(g.record.enabled)
        XCTAssertNil(g.record.pendingSince)
        XCTAssertFalse(g.inProgress)
    }

    func testUnknownAfterTheWakeAbortsAndTheEpisodeStaysSpent() {
        var g = woken()
        g.reading(.unknown, startedAt: 32.1)
        XCTAssertEqual(g.decide(ok, now: 32.4, wallNow: w(32.4)), .finished(.aborted(.lockUnknown)))
        XCTAssertTrue(g.record.episodeAttempted)
        XCTAssertTrue(g.record.enabled)
        XCTAssertNil(g.record.pendingSince)
        g.reading(.locked, startedAt: 40)
        XCTAssertEqual(g.decide(ok, now: 40.1, wallNow: w(40.1)), .nothing(.triedThisEpisode))
    }

    func testNoReadingWithinFiveSecondsAborts() {
        var g = woken()
        XCTAssertEqual(g.decide(ok, now: 37, wallNow: w(37)), .probe)
        XCTAssertEqual(g.decide(ok, now: 37.01, wallNow: w(37.01)), .finished(.aborted(.probeTimeout)))
        XCTAssertEqual(AutoUnlockOutcome.aborted(.probeTimeout).eventReason, "probe_timeout")
    }

    func testAnOldLockedReadingAfterTheWakeIsProbedAgain() {
        var g = woken()
        g.reading(.locked, startedAt: 32.1)
        XCTAssertEqual(g.decide(ok, now: 34.2, wallNow: w(34.2)), .probe)
    }

    func testDisabledBusyOrWDAUpAfterTheWakeAborts() {
        let cases: [(PasscodeGateContext, PasscodeGateHold)] = [
            (PasscodeGateContext(enabled: false, paired: true, attached: true), .disabled),
            (PasscodeGateContext(enabled: true, paired: true, attached: true, keyboardBusy: true), .keyboardBusy),
            (PasscodeGateContext(enabled: true, paired: true, attached: true, wdaUp: true), .wdaUp),
            (PasscodeGateContext(enabled: true, paired: true, attached: true, sheetUp: true), .sheet),
        ]
        for (c, hold) in cases {
            var g = woken()
            g.reading(.locked, startedAt: 32.1)
            XCTAssertEqual(g.decide(c, now: 32.4, wallNow: w(32.4)), .finished(.aborted(hold)))
            XCTAssertNil(g.record.pendingSince)
        }
    }

    func testAnApprovalGoesStaleTwoSecondsAfterItsReading() {
        let a = AutoTypeApproval(udid: udid, readingStartedAt: 10)
        XCTAssertTrue(a.isFresh(now: 12))
        XCTAssertFalse(a.isFresh(now: 12.01))
    }

    func testAFailedWakeEndsWithoutTurningAutoOff() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        _ = g.decide(ok, now: 30.5, wallNow: w(30.5))
        g.wakeStarted(now: 30.5, wallNow: w(30.5))
        g.wakeEnded(now: 31, failure: .dongleUnavailable)
        XCTAssertEqual(g.decide(ok, now: 31, wallNow: w(31)), .finished(.notSent(.dongleUnavailable)))
        XCTAssertTrue(g.record.enabled)
        XCTAssertTrue(g.record.episodeAttempted)
    }
}

/// From the typing to the verdict.
final class PasscodeGateVerifyTests: XCTestCase {
    /// Typed; the SEND ended at 40, its first key 1 s after the reading.
    private func typed(_ r: TypeResult = .sent, firstKeyAge: TimeInterval? = 1) -> PasscodeGate {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        _ = g.decide(ok, now: 30.5, wallNow: w(30.5))
        g.wakeStarted(now: 30.5, wallNow: w(30.5))
        g.wakeEnded(now: 32)
        g.reading(.locked, startedAt: 32.1)
        _ = g.decide(ok, now: 32.4, wallNow: w(32.4))
        g.typingEnded(r, now: 40, firstKeyAgeSec: firstKeyAge)
        return g
    }

    func testNotSentFinishesWithoutTurningAutoOff() {
        var g = typed(.notSent(.dongleUnavailable))
        XCTAssertEqual(g.decide(ok, now: 40, wallNow: w(40)), .finished(.notSent(.dongleUnavailable)))
        XCTAssertTrue(g.record.enabled)
        XCTAssertNil(g.record.pendingSince)
        XCTAssertFalse(AutoUnlockOutcome.notSent(.dongleUnavailable).disables)
    }

    func testSentVerifies() {
        var g = typed()
        XCTAssertEqual(g.decide(ok, now: 40.1, wallNow: w(40.1)), .verifyProbe)
    }

    func testUnlockedAtThreeSecondsIsSuccess() {
        var g = typed()
        g.reading(.unlocked, startedAt: 43)
        XCTAssertEqual(g.decide(ok, now: 43.2, wallNow: w(43.2)), .finished(.unlocked))
        XCTAssertTrue(g.record.enabled)
        XCTAssertNil(g.record.pendingSince)
        XCTAssertFalse(g.record.episodeAttempted, "the unlock ended the episode")
    }

    func testOnlyLockedReadingsFailAndTurnAutoOff() {
        var g = typed()
        for t in stride(from: 41.0, through: 54.0, by: 1.0) {
            g.reading(.locked, startedAt: t)
            XCTAssertEqual(g.decide(ok, now: t + 0.2, wallNow: w(t + 0.2)), .verifyProbe)
        }
        XCTAssertEqual(g.decide(ok, now: 55, wallNow: w(55)), .finished(.stillLocked))
        XCTAssertFalse(g.record.enabled)
        XCTAssertEqual(g.record.disabledReason, .stillLocked)
        XCTAssertEqual(g.record.changedBy, .failure)
        XCTAssertEqual(g.record.state, .offAfterFailure)
        XCTAssertNil(g.record.pendingSince)
    }

    func testOnlyUnknownReadingsAreUnverifiedAndTurnAutoOff() {
        var g = typed()
        g.reading(.unknown, startedAt: 41)
        g.reading(.unknown, startedAt: 50)
        XCTAssertEqual(g.decide(ok, now: 55, wallNow: w(55)), .finished(.unverified))
        XCTAssertFalse(g.record.enabled)
        XCTAssertEqual(g.record.disabledReason, .unverified)
    }

    func testLockedThenUnlockedWithinFiveSecondsIsSuccess() {
        var g = typed()
        g.reading(.locked, startedAt: 41)
        g.reading(.unlocked, startedAt: 45)
        XCTAssertEqual(g.decide(ok, now: 45.2, wallNow: w(45.2)), .finished(.unlocked))
        XCTAssertTrue(g.record.enabled)
    }

    /// A person's Face ID could have done it: not proof the code worked.
    func testAnUnlockAfterFiveSecondsIsUnprovenAndTurnsAutoOff() {
        var g = typed()
        g.reading(.locked, startedAt: 42)
        g.reading(.unlocked, startedAt: 45.1)
        XCTAssertEqual(g.decide(ok, now: 45.3, wallNow: w(45.3)), .finished(.unlockedLate))
        XCTAssertFalse(g.record.enabled)
        XCTAssertEqual(g.record.disabledReason, .unlockedLate)
    }

    /// Seen unlocked after the window: never "stayed locked".
    func testAnUnlockAfterTheWindowIsUnlockedLateNotStillLocked() {
        var g = typed()
        g.reading(.locked, startedAt: 42)
        g.reading(.unlocked, startedAt: 55.1)
        XCTAssertEqual(g.decide(ok, now: 55.3, wallNow: w(55.3)), .finished(.unlockedLate))
    }

    /// A probe that started inside the window gets to answer.
    func testTheWindowWaitsForAProbeStartedInsideIt() {
        var g = typed()
        g.reading(.locked, startedAt: 42)
        var c = ok; c.probeInFlightSince = 54.5
        XCTAssertEqual(g.decide(c, now: 55.2, wallNow: w(55.2)), .nothing(.inProgress))
        XCTAssertEqual(g.decide(c, now: 58.6, wallNow: w(58.6)), .finished(.stillLocked), "not for ever")
        var h = typed()
        h.reading(.locked, startedAt: 42)
        c.probeInFlightSince = 55.5   // started after the window
        XCTAssertEqual(h.decide(c, now: 55.6, wallNow: w(55.6)), .finished(.stillLocked))
    }

    /// The dongle reconnects inside its SEND: a late first key can't be
    /// proven to have hit a locked phone, so even a success turns it off.
    func testALateFirstKeyTurnsAutoOffEvenWhenItUnlocked() {
        var g = typed(firstKeyAge: AutoUnlockTiming.firstKeyMaxSec + 0.1)
        g.reading(.unlocked, startedAt: 41)
        XCTAssertEqual(g.decide(ok, now: 41.2, wallNow: w(41.2)), .finished(.lateFirstKey))
        XCTAssertFalse(g.record.enabled)
        XCTAssertEqual(g.record.disabledReason, .slowKeyboard)
        XCTAssertEqual(AutoUnlockOutcome.lateFirstKey.eventReason, "slow_keyboard")
        var h = typed(firstKeyAge: nil)
        h.reading(.unlocked, startedAt: 41)
        XCTAssertEqual(h.decide(ok, now: 41.2, wallNow: w(41.2)), .finished(.lateFirstKey), "unknown is late")
        var k = typed(firstKeyAge: AutoUnlockTiming.firstKeyMaxSec)
        k.reading(.unlocked, startedAt: 41)
        XCTAssertEqual(k.decide(ok, now: 41.2, wallNow: w(41.2)), .finished(.unlocked))
    }

    func testAStuckPasscodeSendFailsClosed() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        _ = g.decide(ok, now: 30.5, wallNow: w(30.5))
        g.wakeStarted(now: 30.5, wallNow: w(30.5))
        g.wakeEnded(now: 32)
        g.reading(.locked, startedAt: 32.1)
        XCTAssertEqual(g.decide(ok, now: 32.4, wallNow: w(32.4)),
                       .type(AutoTypeApproval(udid: udid, readingStartedAt: 32.1)))
        XCTAssertEqual(g.decide(ok, now: 32.4 + AutoUnlockTiming.sendDeadlineSec, wallNow: w(100)),
                       .nothing(.inProgress))
        XCTAssertEqual(g.decide(ok, now: 32.5 + AutoUnlockTiming.sendDeadlineSec, wallNow: w(100)),
                       .finished(.unverified))
        XCTAssertFalse(g.record.enabled)
        XCTAssertNil(g.record.pendingSince)
        // A late callback changes nothing.
        g.typingEnded(.sent, now: 200, firstKeyAgeSec: 1)
        XCTAssertFalse(g.inProgress)
    }

    func testAStuckWakeEndsUnsentAndStaysOn() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        _ = g.decide(ok, now: 30.5, wallNow: w(30.5))
        g.wakeStarted(now: 30.5, wallNow: w(30.5))
        XCTAssertEqual(g.decide(ok, now: 31 + AutoUnlockTiming.sendDeadlineSec, wallNow: w(100)),
                       .finished(.aborted(.sendStuck)))
        XCTAssertTrue(g.record.enabled)
        XCTAssertTrue(g.record.episodeAttempted, "the episode stays spent")
    }

    func testMaybeSentIsTreatedAsSent() {
        var g = typed(.maybeSent(.sendFailed))
        XCTAssertEqual(g.decide(ok, now: 40.1, wallNow: w(40.1)), .verifyProbe)
        XCTAssertEqual(TypeResult(failure: .sendFailed), .maybeSent(.sendFailed))
        XCTAssertEqual(TypeResult(failure: .dongleError), .maybeSent(.dongleError))
        XCTAssertEqual(TypeResult(failure: .dongleUnavailable), .notSent(.dongleUnavailable))
        XCTAssertEqual(TypeResult(failure: nil), .sent)
    }

    func testAReadingStartedDuringTypingIsIgnored() {
        var g = typed()
        g.reading(.unlocked, startedAt: 39)   // started before typing ended
        XCTAssertEqual(g.decide(ok, now: 40.1, wallNow: w(40.1)), .verifyProbe)
        XCTAssertEqual(g.decide(ok, now: 55, wallNow: w(55)), .finished(.unverified))
    }
}

final class PasscodeGateEpisodeTests: XCTestCase {
    private func attemptAndUnlock(_ g: inout PasscodeGate, from t: TimeInterval) {
        g.reading(.locked, startedAt: t)
        g.reading(.locked, startedAt: t + 30)
        XCTAssertEqual(g.decide(ok, now: t + 30.5, wallNow: w(t + 30.5)), .wake)
        g.wakeStarted(now: t + 30.5, wallNow: w(t + 30.5))
        g.wakeEnded(now: t + 32)
        g.reading(.locked, startedAt: t + 32.1)
        _ = g.decide(ok, now: t + 32.4, wallNow: w(t + 32.4))
        g.typingEnded(.sent, now: t + 40, firstKeyAgeSec: 1)
        g.reading(.unlocked, startedAt: t + 41)
        XCTAssertEqual(g.decide(ok, now: t + 41.2, wallNow: w(t + 41.2)), .finished(.unlocked))
    }

    func testARelockIsANewEpisodeButTheGapAndSettleStillApply() {
        var g = PasscodeGate(udid: udid, history: on())
        attemptAndUnlock(&g, from: 0)
        g.reading(.locked, startedAt: 60)
        XCTAssertEqual(g.decide(ok, now: 60.2, wallNow: w(60.2)), .nothing(.settling))
        g.reading(.locked, startedAt: 80)
        XCTAssertEqual(g.decide(ok, now: 80.2, wallNow: w(80.2)), .nothing(.tooSoon))
        g.reading(.locked, startedAt: 151)
        XCTAssertEqual(g.decide(ok, now: 151.2, wallNow: w(151.2)), .wake)
    }

    func testOffAfterAFailureStaysOff() {
        var r = on(); r.disable(reason: .stillLocked, by: .failure, at: wall0)
        var g = PasscodeGate(udid: udid, history: r)
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 30)
        XCTAssertEqual(g.decide(ok, now: 30.2, wallNow: w(30.2)), .nothing(.disabled))
    }

    func testReenablingInTheSameEpisodeBuysNoSecondTry() {
        var r = on(); r.episodeAttempted = true
        r.disable(reason: .stillLocked, by: .failure, at: wall0)
        var g = PasscodeGate(udid: udid, history: r)
        g.setEnabled(true, by: .settings, wallNow: w(1))
        XCTAssertNil(g.record.disabledReason)
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 300)
        XCTAssertEqual(g.decide(ok, now: 300.2, wallNow: w(300.2)), .nothing(.triedThisEpisode))
    }

    func testReenablingAfterAnUnlockAllows() {
        var r = on(); r.episodeAttempted = true
        var g = PasscodeGate(udid: udid, history: r)
        g.reading(.unlocked, startedAt: 0)
        g.reading(.locked, startedAt: 10)
        g.reading(.locked, startedAt: 300)
        XCTAssertEqual(g.decide(ok, now: 300.2, wallNow: w(300.2)), .wake)
    }

    func testTwoPhonesAreIndependent() {
        var a = PasscodeGate(udid: udid, history: on())
        var b = PasscodeGate(udid: "00008150-001928E01404401C", history: AutoUnlockRecord())
        for t in [0.0, 30.0] { a.reading(.locked, startedAt: t); b.reading(.locked, startedAt: t) }
        XCTAssertEqual(a.decide(ok, now: 30.2, wallNow: w(30.2)), .wake)
        XCTAssertEqual(b.decide(ok, now: 30.2, wallNow: w(30.2)), .nothing(.disabled), "the iPhone 17 is off")
        a.wakeStarted(now: 30.2, wallNow: w(30.2))
        XCTAssertFalse(b.record.episodeAttempted)
        XCTAssertTrue(b.record.attempts.isEmpty)
    }

    /// A wrong clicked code must not be followed by the same wrong
    /// value typed automatically in the same lock.
    func testAClickSpendsTheEpisodeAndCountsTowardTheGap() {
        var g = PasscodeGate(udid: udid, history: on())
        g.reading(.locked, startedAt: 0)
        g.reading(.locked, startedAt: 8)
        g.clickTyped(wallNow: w(10), now: 10)
        g.reading(.locked, startedAt: 25)
        XCTAssertEqual(g.decide(ok, now: 25.2, wallNow: w(25.2)), .nothing(.triedThisEpisode))
        XCTAssertEqual(g.record.attempts, [w(10)])
        // A new lock still waits the gap after the click.
        g.reading(.unlocked, startedAt: 30)
        g.reading(.locked, startedAt: 40)
        g.reading(.locked, startedAt: 70)
        XCTAssertEqual(g.decide(ok, now: 70.2, wallNow: w(70.2)), .nothing(.tooSoon))
    }

    func testAnOutOfOrderUnlockedReadingEndsNothing() {
        var r = on(); r.episodeAttempted = true
        var g = PasscodeGate(udid: udid, history: r)
        g.reading(.locked, startedAt: 10)
        g.reading(.unlocked, startedAt: 9)   // started earlier: dropped
        XCTAssertTrue(g.record.episodeAttempted)
    }

    func testMayStillActOnlyWhileATryIsPossibleAndBounded() {
        var g = PasscodeGate(udid: udid, history: on())
        XCTAssertFalse(g.mayStillAct(now: 0), "no lock")
        g.reading(.locked, startedAt: 0)
        XCTAssertTrue(g.mayStillAct(now: 30))
        XCTAssertFalse(g.mayStillAct(now: AutoUnlockTiming.keepAwakeLockedSec + 1), "bounded")
        var off = PasscodeGate(udid: udid, history: AutoUnlockRecord())
        off.reading(.locked, startedAt: 0)
        XCTAssertFalse(off.mayStillAct(now: 30), "auto-unlock off: a locked phone needs a person")
        g.clickTyped(wallNow: w(1), now: 1)
        XCTAssertFalse(g.mayStillAct(now: 30), "episode spent")
    }

    /// No lock being read: the click still counts toward the gap, but
    /// leaves the next lock its try.
    func testAClickOnAnUnreadPhoneOnlyCountsTowardTheGap() {
        var g = PasscodeGate(udid: udid, history: on())
        g.clickTyped(wallNow: w(0), now: 0)
        XCTAssertFalse(g.record.episodeAttempted)
        XCTAssertEqual(g.record.attempts, [w(0)])
        var h = PasscodeGate(udid: udid, history: on())
        h.reading(.locked, startedAt: 0)
        h.clickTyped(wallNow: w(16), now: 16)   // that reading is too old
        XCTAssertFalse(h.record.episodeAttempted)
        g.reading(.locked, startedAt: 200)
        g.reading(.locked, startedAt: 230)
        XCTAssertEqual(g.decide(ok, now: 230.2, wallNow: w(230.2)), .wake)
    }

    func testAFailedClickTurnsAutoOff() {
        var g = PasscodeGate(udid: udid, history: on())
        g.clickFailed(wallNow: w(5))
        XCTAssertEqual(g.record.state, .offAfterFailure)
        XCTAssertEqual(g.record.disabledReason, .stillLocked)
    }
}

final class ClickVerifyTests: XCTestCase {
    func testOnlyAClickOnARecentLockIsChecked() {
        XCTAssertNil(ClickVerify(typedAt: 100, lastBefore: nil))
        XCTAssertNil(ClickVerify(typedAt: 100, lastBefore: LockSample(.unlocked, startedAt: 99)))
        XCTAssertNil(ClickVerify(typedAt: 100, lastBefore: LockSample(.locked, startedAt: 84)))
        XCTAssertNotNil(ClickVerify(typedAt: 100, lastBefore: LockSample(.locked, startedAt: 90)))
    }

    func testOutcomes() throws {
        var v = try XCTUnwrap(ClickVerify(typedAt: 100, lastBefore: LockSample(.locked, startedAt: 95)))
        XCTAssertNil(v.outcome(now: 101))
        v.reading(.locked, startedAt: 99)   // before typing: ignored
        v.reading(.locked, startedAt: 101)
        XCTAssertNil(v.outcome(now: 114))
        XCTAssertEqual(v.outcome(now: 115), .stillLocked)
        v.reading(.unlocked, startedAt: 112)
        XCTAssertEqual(v.outcome(now: 115), .unlocked)
        var u = try XCTUnwrap(ClickVerify(typedAt: 100, lastBefore: LockSample(.locked, startedAt: 95)))
        u.reading(.unknown, startedAt: 101)
        XCTAssertEqual(u.outcome(now: 115), .unverified)
    }
}
