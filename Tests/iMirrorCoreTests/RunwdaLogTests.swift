import XCTest
@testable import iMirrorCore

/// go-ios's slog line when testmanagerd sits on the XCTest passcode sheet.
private let sheetLine = #"{"time":"2026-11-13T22:39:05.1Z","level":"ERROR","msg":"Failed running WDA","#
    + #""error":"runXUITestWithBundleIdsXcode15Ctx: cannot initiate a IDE session: Timed out waiting "#
    + #"for response for message:5 channel:-1"}"#

final class RunwdaLogTests: XCTestCase {
    func testTheSheetTimeoutNeedsAPasscode() {
        XCTAssertEqual(classifyRunwdaLine(sheetLine), .needsPasscode)
        XCTAssertEqual(classifyRunwdaLine("cannot initiate a IDE session: Timed out"), .needsPasscode)
    }

    func testAnIDESessionErrorWithoutATimeoutIsNotTheSheet() {
        XCTAssertNil(classifyRunwdaLine("cannot initiate a IDE session: connection reset by peer"))
    }

    func testLockedPhone() {
        XCTAssertEqual(classifyRunwdaLine(
            "Could not start service:com.apple.testmanagerd.lockdown with reason:'PasswordProtected'"), .locked)
        XCTAssertEqual(classifyRunwdaLine("error: the device is locked"), .locked)
    }

    func testUntrustedMacOrDeveloper() {
        XCTAssertEqual(classifyRunwdaLine("Please accept the PairingDialog on the device and run pairing again!"),
                       .untrusted)
        XCTAssertEqual(classifyRunwdaLine(#"{"error":"lockdown: InvalidHostID"}"#), .untrusted)
        XCTAssertEqual(classifyRunwdaLine(
            "its profile has not been explicitly trusted by the user"), .untrusted)
    }

    func testOrdinaryLinesSayNothing() {
        XCTAssertNil(classifyRunwdaLine(#"{"level":"INFO","msg":"Running wda"}"#))
        XCTAssertNil(classifyRunwdaLog(""))
    }

    func testTheNewestClassifiedLineWins() {
        XCTAssertEqual(classifyRunwdaLog("device is locked\nhello\n" + sheetLine + "\nstill waiting"),
                       .needsPasscode)
    }

    func testEachClassMapsToItsReason() {
        XCTAssertEqual(RunwdaLogClass.needsPasscode.reason, .needsPasscode)
        XCTAssertEqual(RunwdaLogClass.locked.reason, .locked)
        XCTAssertEqual(RunwdaLogClass.untrusted.reason, .untrusted)
    }

    func testTheReasonFromRunwdaBeatsTheLaddersOwn() {
        let i = DeviceReasonInputs(ready: false, runwda: .needsPasscode, gaveUp: true, everConnected: true)
        XCTAssertEqual(deviceReason(i), .needsPasscode)
        XCTAssertNil(deviceReason(DeviceReasonInputs(ready: true, runwda: .locked)))
    }

    func testErrorSummaryIsMsgAndErrorFromGoIOSErrorLinesOnly() {
        XCTAssertEqual(runwdaErrorSummary(sheetLine),
                       "Failed running WDA: runXUITestWithBundleIdsXcode15Ctx: cannot initiate a IDE "
                       + "session: Timed out waiting for response for message:5 channel:-1")
        XCTAssertNil(runwdaErrorSummary(#"{"level":"INFO","msg":"Running wda"}"#))
        // Runner output may echo typed text: never kept.
        XCTAssertNil(runwdaErrorSummary("error typing 'hunter2' into field"))
    }

    func testErrorSummaryIsBounded() {
        let long = #"{"level":"ERROR","msg":""# + String(repeating: "x", count: 500) + #""}"#
        XCTAssertEqual(runwdaErrorSummary(long, maxLength: 50)?.count, 51)
    }
}

final class OutputRingTests: XCTestCase {
    func testReturnsOnlyCompletedLines() {
        var r = OutputRing()
        XCTAssertEqual(r.append(Data("one\ntw".utf8)), ["one"])
        XCTAssertEqual(r.append(Data("o\nthree\n".utf8)), ["two", "three"])
        XCTAssertEqual(r.text, "one\ntwo\nthree\n")
    }

    func testKeepsOnlyTheNewestBytes() {
        var r = OutputRing(capacity: 8)
        _ = r.append(Data("0123456789\n".utf8))
        XCTAssertEqual(r.text, "3456789\n")
    }

    func testARunawayLineCannotGrowMemory() {
        var r = OutputRing(capacity: 8)
        for _ in 0..<100 { _ = r.append(Data("xxxxxxxx".utf8)) }
        XCTAssertEqual(r.append(Data("\n".utf8)), ["xxxxxxxx"])
    }
}

final class PasscodeHoldTests: XCTestCase {
    func testHoldsFromTheFirstSheetUntilTheCap() {
        var h = PasscodeHold()
        XCTAssertFalse(h.holding(now: 0))
        h.sheetSeen(now: 100)
        h.sheetSeen(now: 400)                    // later sightings don't extend it
        XCTAssertTrue(h.holding(now: 100 + PasscodeHold.capSec - 1))
        XCTAssertFalse(h.holding(now: 100 + PasscodeHold.capSec))
    }

    func testARunOutHoldStaysOutUntilCleared() {
        var h = PasscodeHold()
        h.sheetSeen(now: 0)
        h.sheetSeen(now: PasscodeHold.capSec + 5)
        XCTAssertFalse(h.holding(now: PasscodeHold.capSec + 5))
        h.clear()
        h.sheetSeen(now: 2_000)
        XCTAssertTrue(h.holding(now: 2_001))
    }

    func testCapIsTenMinutes() { XCTAssertEqual(PasscodeHold.capSec, 600) }
}

final class HeldRunwdaTests: XCTestCase {
    func testAHeldRunwdaIsNeverReadinessKilled() {
        XCTAssertTrue(managedProcessShouldKillForUnreadiness(uptime: 41, readySeen: false, readyWithin: 40))
        XCTAssertFalse(managedProcessShouldKillForUnreadiness(uptime: 41, readySeen: false, readyWithin: 40,
                                                              held: true))
    }

    func testAHeldRunwdaRespawnsAtASteadyPace() {
        XCTAssertEqual(managedProcessRespawnDelay(base: 6, failures: 1, held: false), 6)
        XCTAssertEqual(managedProcessRespawnDelay(base: 6, failures: 3, held: false), 24)
        XCTAssertEqual(managedProcessRespawnDelay(base: 6, failures: 9, held: false), 60)
        XCTAssertEqual(managedProcessRespawnDelay(base: 6, failures: 9, held: true), 15)
    }

    func testTheLadderPausesWhileHeld() {
        var l = ChainLadderState()
        l.onConnected()
        l.onDown(now: 0)
        XCTAssertEqual(l.tick(now: 1_000, othersHealthy: false, tunnelHasDevice: true, held: true), .wait)
        XCTAssertEqual(l.stage, 0)
        XCTAssertEqual(l.tick(now: 1_000, othersHealthy: false, tunnelHasDevice: true), .restartDeviceChain)
    }

    func testAGivenUpLadderStillRetriesWhileHeld() {
        var l = ChainLadderState()
        l.hardStop(now: 0)
        XCTAssertEqual(l.tick(now: 1_000, othersHealthy: false, tunnelHasDevice: true, held: true), .autoRetry)
    }
}
