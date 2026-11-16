import XCTest
@testable import iMirrorCore

final class LockProbeParsingTests: XCTestCase {
    private func read(_ out: String, status: Int32 = 0, timedOut: Bool = false) -> LockReading {
        LockProbeParsing.reading(status: status, stdout: Data(out.utf8), timedOut: timedOut)
    }

    /// The bytes go-ios printed on the unlocked 16e (2026-11-16).
    func testFalseIsUnlocked() {
        XCTAssertEqual(LockProbeParsing.reading(status: 0, stdout: Data([0x66, 0x61, 0x6c, 0x73, 0x65, 0x0a]),
                                                timedOut: false), .unlocked)
    }

    func testTrueIsLocked() {
        XCTAssertEqual(read("true\n"), .locked)
        XCTAssertEqual(read("  true \r\n"), .locked)
    }

    /// go-ios ignores lockdown's error and prints null with exit 0.
    func testNullIsUnknown() {
        XCTAssertEqual(read("null\n"), .unknown)
    }

    func testDeviceNotFoundIsUnknown() {
        XCTAssertEqual(read("", status: 1), .unknown)
        XCTAssertEqual(read("true\n", status: 1), .unknown)
    }

    func testATimeoutIsUnknownWhateverItPrinted() {
        XCTAssertEqual(read("true\n", timedOut: true), .unknown)
        XCTAssertEqual(read("false\n", timedOut: true), .unknown)
    }

    func testOnlyTheExactWordsCount() {
        for odd in ["True", "1", "\"true\"", "TRUE", "yes", "false\ntrue\n", "", "\n", "truefalse"] {
            XCTAssertEqual(read(odd), .unknown, odd)
        }
    }

    func testArgsAreExact() {
        XCTAssertEqual(LockProbeParsing.args(udid: "00008140-0006423002D3401C"),
                       ["lockdown", "get", "PasswordProtected", "--udid=00008140-0006423002D3401C"])
    }

    func testABadUDIDGivesNoArgs() {
        for bad in ["", "../x", "a b", "u;rm", "x/y"] { XCTAssertNil(LockProbeParsing.args(udid: bad), bad) }
    }
}

final class LockWatchTests: XCTestCase {
    func testNoReadingsIsNotLocked() {
        XCTAssertFalse(LockWatch().isLocked(now: 0))
        XCTAssertNil(LockWatch().episodeStart)
    }

    func testALockedReadingCountsForFifteenSeconds() {
        var w = LockWatch()
        w.record(.locked, startedAt: 100)
        XCTAssertTrue(w.isLocked(now: 115))
        XCTAssertFalse(w.isLocked(now: 115.01))
    }

    func testAnUnknownReadingNeitherRefreshesNorTransitions() {
        var w = LockWatch()
        w.record(.locked, startedAt: 100)
        XCTAssertNil(w.record(.unknown, startedAt: 110))
        XCTAssertEqual(w.latest, LockSample(.unknown, startedAt: 110))
        XCTAssertFalse(w.isLocked(now: 116), "the unknown did not extend the lock")
        XCTAssertNil(w.record(.locked, startedAt: 120), "locked to locked, through an unknown")
    }

    func testTransitions() {
        var w = LockWatch()
        XCTAssertNil(w.record(.unlocked, startedAt: 1), "a first unlocked reading changes nothing")
        XCTAssertEqual(w.record(.locked, startedAt: 2), .becameLocked)
        XCTAssertNil(w.record(.locked, startedAt: 3))
        XCTAssertEqual(w.record(.unlocked, startedAt: 4), .becameUnlocked)
        XCTAssertNil(w.record(.unlocked, startedAt: 5))
        var first = LockWatch()
        XCTAssertEqual(first.record(.locked, startedAt: 1), .becameLocked, "logged once per episode")
    }

    func testAnOlderReadingIsDropped() {
        var w = LockWatch()
        w.record(.locked, startedAt: 10)
        XCTAssertNil(w.record(.unlocked, startedAt: 9))
        XCTAssertTrue(w.isLocked(now: 11))
    }

    func testTheEpisodeOutlivesUnknownsAndGapsButNotAnUnlock() {
        var w = LockWatch()
        w.record(.locked, startedAt: 10)
        XCTAssertEqual(w.episodeStart, 10)
        w.record(.unknown, startedAt: 20)
        w.record(.locked, startedAt: 100)   // a gap far past 15 s
        XCTAssertEqual(w.episodeStart, 10)
        w.record(.unlocked, startedAt: 110)
        XCTAssertNil(w.episodeStart)
        w.record(.locked, startedAt: 120)
        XCTAssertEqual(w.episodeStart, 120)
    }
}

final class FirstKeyAgeTests: XCTestCase {
    func testASeenFirstKeyIsExact() {
        XCTAssertEqual(FirstKeyAge.seconds(readingStartedAt: 10, firstKeyAt: 11.5, sendStartedAt: 10.2,
                                           sendEndedAt: 30, stepDelaysMs: 0), 1.5)
    }

    /// The dongle: SEND end minus its own delays, an upper bound.
    func testTheDongleIsBoundedByTheSendsEndLessItsDelays() {
        // Open 0.2, reconnect 12, settle 1, delays 2 seconds.
        let slow = FirstKeyAge.seconds(readingStartedAt: 10, firstKeyAt: nil, sendStartedAt: 10.2,
                                       sendEndedAt: 25.4, stepDelaysMs: 2000)
        XCTAssertEqual(slow, 13.4, accuracy: 0.001)
        XCTAssertGreaterThan(slow, AutoUnlockTiming.firstKeyMaxSec)
        let fast = FirstKeyAge.seconds(readingStartedAt: 10, firstKeyAt: nil, sendStartedAt: 10.2,
                                       sendEndedAt: 14.0, stepDelaysMs: 2000)
        XCTAssertEqual(fast, 2.0, accuracy: 0.001)
        // Never earlier than the SEND's start.
        XCTAssertEqual(FirstKeyAge.seconds(readingStartedAt: 10, firstKeyAt: nil, sendStartedAt: 10.5,
                                           sendEndedAt: 11, stepDelaysMs: 5000), 0.5, accuracy: 0.001)
    }
}
