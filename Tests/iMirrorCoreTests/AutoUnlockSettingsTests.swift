import XCTest
@testable import iMirrorCore

private let phone16e = "00008140-0006423002D3401C"
private let phone17 = "00008150-001928E01404401C"
private let now = Date(timeIntervalSince1970: 1_794_700_000)

final class AutoUnlockSettingsTests: XCTestCase {
    private func load(_ json: String) -> (AutoUnlockSettings, interrupted: [String]) {
        AutoUnlockSettings.load(Data(json.utf8), wallNow: now)
    }

    func testNothingStoredMeansEveryPhoneIsOff() {
        let (s, interrupted) = AutoUnlockSettings.load(nil, wallNow: now)
        XCTAssertFalse(s.record(for: phone16e).enabled)
        XCTAssertFalse(s.record(for: phone17).enabled)
        XCTAssertEqual(s.record(for: phone17).state, .off)
        XCTAssertEqual(interrupted, [])
    }

    func testGarbageIsAllOff() {
        for junk in ["", "[]", "{\"x", "null", "42", "{\"\(phone16e)\": 1}", "{\"\(phone16e)\": []}"] {
            let (s, _) = load(junk)
            XCTAssertFalse(s.record(for: phone16e).enabled, junk)
        }
    }

    func testANonBoolEnabledIsOff() {
        for v in ["1", "\"true\"", "null", "{}"] {
            let (s, _) = load("{\"\(phone16e)\": {\"enabled\": \(v)}}")
            XCTAssertFalse(s.record(for: phone16e).enabled, v)
        }
        let (s, _) = load("{\"\(phone16e)\": {\"enabled\": true}}")
        XCTAssertTrue(s.record(for: phone16e).enabled)
    }

    func testAnUnknownKeyOrBadUDIDIsOff() {
        let (s, _) = load("{\"\(phone16e)\": {\"enabled\": true, \"passcode\": \"222222\"}}")
        XCTAssertFalse(s.record(for: phone16e).enabled)
        XCTAssertTrue(s.record(for: phone16e).episodeAttempted, "an odd entry spends its episode")
        let (t, _) = load("{\"../x\": {\"enabled\": true}}")
        XCTAssertTrue(t.records.isEmpty)
    }

    func testRoundTripGivesTheSameBytes() {
        var s = AutoUnlockSettings()
        s.enable(udid: phone16e, by: .settings, at: now)
        var r = s.record(for: phone16e)
        r.attempts = [now.addingTimeInterval(-600), now.addingTimeInterval(-60)]
        r.episodeAttempted = true
        s.set(r, for: phone16e)
        s.disable(udid: phone17, reason: .unverified, by: .failure, at: now)
        let bytes = s.encode()
        let (back, interrupted) = AutoUnlockSettings.load(bytes, wallNow: now)
        XCTAssertEqual(back, s)
        XCTAssertEqual(interrupted, [])
        XCTAssertEqual(back.encode(), bytes)
        XCTAssertEqual(back.record(for: phone17).state, .offAfterFailure)
    }

    func testAttemptsArePrunedToAnHourAndTen() {
        var s = AutoUnlockSettings()
        var r = AutoUnlockRecord()
        r.enabled = true
        r.attempts = [now.addingTimeInterval(-3601)] + (1...12).map { now.addingTimeInterval(-Double($0) * 100) }.reversed()
        s.set(r, for: phone16e)
        let (back, _) = AutoUnlockSettings.load(s.encode(), wallNow: now)
        let a = back.record(for: phone16e).attempts
        XCTAssertEqual(a.count, 10)
        XCTAssertEqual(a.last, now.addingTimeInterval(-100))
        XCTAssertTrue(a.allSatisfy { now.timeIntervalSince($0) < 3600 })
    }

    func testPendingOnLoadMeansInterrupted() {
        var s = AutoUnlockSettings()
        s.enable(udid: phone16e, by: .settings, at: now)
        var r = s.record(for: phone16e)
        r.pendingSince = now.addingTimeInterval(-30)
        s.set(r, for: phone16e)
        let (back, interrupted) = AutoUnlockSettings.load(s.encode(), wallNow: now)
        XCTAssertEqual(interrupted, [phone16e])
        let b = back.record(for: phone16e)
        XCTAssertFalse(b.enabled)
        XCTAssertEqual(b.disabledReason, .interrupted)
        XCTAssertEqual(b.changedBy, .failure)
        XCTAssertNil(b.pendingSince)
        XCTAssertEqual(b.state, .offAfterFailure)
    }

    func testOnlyWhitelistedKeysAndNoPasscode() throws {
        var s = AutoUnlockSettings()
        s.enable(udid: phone16e, by: .request, at: now)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: s.encode()) as? [String: [String: Any]])
        let keys = Set(try XCTUnwrap(obj[phone16e]).keys)
        XCTAssertEqual(keys, AutoUnlockSettings.allowedKeys)
        XCTAssertFalse(keys.contains { $0.lowercased().contains("passcode") })
        XCTAssertFalse(String(decoding: s.encode(), as: UTF8.self).lowercased().contains("passcode"))
    }

    func testEnableClearsTheReasonAndKeepsHistory() {
        var r = AutoUnlockRecord()
        r.attempts = [now]
        r.episodeAttempted = true
        r.disable(reason: .stillLocked, by: .failure, at: now)
        r.enable(by: .settings, at: now.addingTimeInterval(5))
        XCTAssertTrue(r.enabled)
        XCTAssertNil(r.disabledReason)
        XCTAssertEqual(r.attempts, [now])
        XCTAssertTrue(r.episodeAttempted)
        XCTAssertEqual(r.changedBy, .settings)
    }

    func testAnUnlockedReadingEndsTheEpisode() {
        var s = AutoUnlockSettings()
        var r = AutoUnlockRecord()
        r.episodeAttempted = true
        s.set(r, for: phone16e)
        s.noteUnlocked(udid: phone16e)
        XCTAssertFalse(s.record(for: phone16e).episodeAttempted)
    }

    func testAPersonTurningItOffStoresNoFailure() {
        var r = AutoUnlockRecord()
        r.enable(by: .settings, at: now)
        r.disable(reason: .settings, by: .settings, at: now)
        XCTAssertNil(r.disabledReason)
        XCTAssertEqual(r.state, .off)
    }

    func testOnAndFailedAtOnceReadsAsOff() {
        let (s, _) = load("{\"\(phone16e)\": {\"enabled\": true, \"disabled_reason\": \"still_locked\"}}")
        XCTAssertFalse(s.record(for: phone16e).enabled)
    }
}
