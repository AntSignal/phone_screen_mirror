import XCTest
@testable import iMirrorCore

final class LockedReasonTests: XCTestCase {
    func testLockedBeatsGaveUpTunnelDownAndBooting() {
        let i = DeviceReasonInputs(ready: false, gaveUp: true, macAsleep: true, usbReset: true,
                                   tunnelHasDevice: false, restarting: true, locked: true)
        XCTAssertEqual(deviceReason(i), .locked)
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, locked: true)), .locked)
        XCTAssertNil(deviceReason(DeviceReasonInputs(ready: true, locked: true)))
    }

    func testTheSheetAndTrustBeatLocked() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, runwda: .needsPasscode, locked: true)),
                       .needsPasscode)
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, runwda: .untrusted, locked: true)), .untrusted)
    }

    func testNotLockedKeepsTheOldOrder() {
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, gaveUp: true, tunnelHasDevice: false)), .gaveUp)
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false, tunnelHasDevice: false)), .tunnelDown)
        XCTAssertEqual(deviceReason(DeviceReasonInputs(ready: false)), .booting)
    }

    func testTheLockEventKind() {
        XCTAssertEqual(DeviceEventKind.lock.rawValue, "lock")
    }
}

final class LockLadderTests: XCTestCase {
    /// The 2026-11-16 00:04–01:10Z episode: phone2 locked, the tunnel
    /// unable to reach it, another phone up. It churned 12 tunnel restarts
    /// an hour. Held, it restarts nothing for two hours.
    func testALockedPhoneHoldsOnceThenWaitsForHours() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        ladder.onConnected()
        ladder.onDown(now: 10)
        var actions: [DeviceRecoveryAction] = []
        for t in stride(from: 10.0, through: 7210.0, by: 3.0) {
            actions.append(ladder.tick(now: t, othersHealthy: true, tunnelHasDevice: false, locked: true))
        }
        XCTAssertEqual(actions.first, .holdForLock)
        XCTAssertEqual(actions.filter { $0 == .holdForLock }.count, 1)
        XCTAssertTrue(actions.dropFirst().allSatisfy { $0 == .wait })
        XCTAssertFalse(ladder.hardStopped)
        XCTAssertNil(ladder.nextAutoRetryAt)
        XCTAssertEqual(ladder.giveUps, 0)
    }

    func testALockAfterAGiveUpClearsTheBackoffButKeepsTheCount() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        ladder.hardStop(now: 50)
        XCTAssertNotNil(ladder.nextAutoRetryAt)
        XCTAssertEqual(ladder.tick(now: 60, othersHealthy: true, tunnelHasDevice: false, locked: true), .holdForLock)
        XCTAssertFalse(ladder.hardStopped)
        XCTAssertNil(ladder.nextAutoRetryAt)
        XCTAssertEqual(ladder.giveUps, 1)
        XCTAssertEqual(ladder.tick(now: 1_000, othersHealthy: true, tunnelHasDevice: false, locked: true), .wait)
        ladder.noteUnlocked(now: 1_001)
        XCTAssertEqual(ladder.giveUps, 0)
    }

    private func heldThenUnlocked(at t: TimeInterval = 100) -> ChainLadderState {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        _ = ladder.tick(now: 10, othersHealthy: true, tunnelHasDevice: false, locked: true)
        ladder.noteUnlocked(now: t)
        return ladder
    }

    func testAnUnlockWithTheTunnelListingThePhoneRestartsItsChain() {
        var ladder = heldThenUnlocked()
        XCTAssertEqual(ladder.tick(now: 101, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        XCTAssertEqual(ladder.stage, 1)
        XCTAssertEqual(ladder.wedgeSince, 101)
    }

    func testAnUnlockWithNoOtherPhoneUpRestartsTheTunnelAtOnce() {
        var ladder = heldThenUnlocked()
        XCTAssertEqual(ladder.tick(now: 101, othersHealthy: false, tunnelHasDevice: false), .restartTunnelAndChains)
        XCTAssertEqual(ladder.stage, 2)
    }

    func testAnUnlockWithOthersUpWaitsForGoIOSFirst() {
        var ladder = heldThenUnlocked()
        XCTAssertEqual(ladder.tick(now: 119.9, othersHealthy: true, tunnelHasDevice: false), .wait)
        XCTAssertEqual(ladder.tick(now: 120, othersHealthy: true, tunnelHasDevice: false), .restartTunnelAndChains)
        XCTAssertNil(ladder.unlockedAt)
    }

    func testAnUnlockLetsTheTunnelBeRestartedAgain() {
        var ladder = ChainLadderState()
        ladder.hardStop(now: 0)
        ladder.hardStop(now: 1)
        XCTAssertFalse(ChainLadderState.retryMayRestartTunnel(giveUps: ladder.giveUps, othersHealthy: true))
        ladder.noteUnlocked(now: 2)
        XCTAssertTrue(ChainLadderState.retryMayRestartTunnel(giveUps: ladder.giveUps, othersHealthy: true))
        XCTAssertFalse(ladder.hardStopped)
    }

    func testAfterTheUnlockRestartTheUsualClimbComesBack() {
        var ladder = heldThenUnlocked()
        XCTAssertEqual(ladder.tick(now: 101, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
        ladder.onRunwdaStarted(now: 105)
        XCTAssertEqual(ladder.tick(now: 194, othersHealthy: true, tunnelHasDevice: true), .wait)
        XCTAssertEqual(ladder.tick(now: 195, othersHealthy: true, tunnelHasDevice: true), .giveUp)
    }

    func testConnectingClearsTheHoldAndThePendingUnlock() {
        var ladder = heldThenUnlocked()
        XCTAssertNotNil(ladder.unlockedAt)
        ladder.onConnected()
        XCTAssertNil(ladder.unlockedAt)
        XCTAssertFalse(ladder.lockHeld)
        var held = ChainLadderState()
        _ = held.tick(now: 1, othersHealthy: true, tunnelHasDevice: true, locked: true)
        XCTAssertTrue(held.lockHeld)
        held.onConnected()
        XCTAssertFalse(held.lockHeld)
    }

    func testTheSheetWithALockWaitsWithoutStoppingRunwda() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        XCTAssertEqual(ladder.tick(now: 500, othersHealthy: false, tunnelHasDevice: true, held: true, locked: true),
                       .wait)
        XCTAssertFalse(ladder.lockHeld)
    }

    func testAClickUnlockWithNoHoldStillRestarts() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        ladder.noteUnlocked(now: 5)
        XCTAssertEqual(ladder.tick(now: 6, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
    }

    func testARestartWhileLockedHoldsAgain() {
        var ladder = ChainLadderState()
        XCTAssertEqual(ladder.tick(now: 1, othersHealthy: true, tunnelHasDevice: false, locked: true), .holdForLock)
        ladder.noteTunnelRestart(now: 2)
        XCTAssertEqual(ladder.tick(now: 3, othersHealthy: true, tunnelHasDevice: false, locked: true), .holdForLock)
        ladder.forceRetry(now: 4)
        XCTAssertEqual(ladder.tick(now: 5, othersHealthy: true, tunnelHasDevice: false, locked: true), .holdForLock)
    }

    /// With the tunnel still listing the phone, a health blip may heal
    /// by itself, so the stage's grace runs before the children stop.
    func testATunnelListingTheLockedPhoneGetsTheGraceFirst() {
        var ladder = ChainLadderState()
        ladder.onRunwdaStarted(now: 0)
        ladder.onConnected()
        ladder.onDown(now: 10)
        let grace = chainRecoveryGraceSec(stage: 0, postConnectionOutage: true)
        XCTAssertEqual(ladder.tick(now: 10 + grace - 0.1, othersHealthy: true, tunnelHasDevice: true, locked: true),
                       .wait)
        XCTAssertFalse(ladder.lockHeld)
        XCTAssertEqual(ladder.tick(now: 10 + grace, othersHealthy: true, tunnelHasDevice: true, locked: true),
                       .holdForLock)
        XCTAssertEqual(ladder.stage, 0, "no restart was spent")
    }

    /// The tunnel's 120 s cooldown refused the restart after an unlock:
    /// ask again soon, instead of climbing to a give-up and a backoff.
    func testARefusedTunnelRestartAfterAnUnlockIsAskedAgain() {
        var ladder = heldThenUnlocked()
        XCTAssertEqual(ladder.tick(now: 101, othersHealthy: false, tunnelHasDevice: false), .restartTunnelAndChains)
        ladder.tunnelRestartRefusedAfterUnlock(now: 101)
        let retry = 101 + AutoUnlockTiming.unlockTunnelRetrySec
        XCTAssertEqual(ladder.tick(now: retry - 0.1, othersHealthy: true, tunnelHasDevice: false), .wait)
        XCTAssertEqual(ladder.tick(now: retry, othersHealthy: true, tunnelHasDevice: false), .restartTunnelAndChains)
        XCTAssertFalse(ladder.hardStopped)
        // The tunnel lists it meanwhile: its own chain at once.
        ladder.tunnelRestartRefusedAfterUnlock(now: retry)
        XCTAssertEqual(ladder.tick(now: retry + 1, othersHealthy: true, tunnelHasDevice: true), .restartDeviceChain)
    }

    func testRefusedTunnelRestartsAfterAnUnlockAreBounded() {
        var ladder = heldThenUnlocked()
        var t: TimeInterval = 101
        var asked = 0
        for _ in 0..<200 {
            guard ladder.unlockedAt != nil else { break }
            if ladder.tick(now: t, othersHealthy: false, tunnelHasDevice: false) == .restartTunnelAndChains {
                asked += 1
                ladder.tunnelRestartRefusedAfterUnlock(now: t)
            }
            t += 1
        }
        XCTAssertEqual(asked, 1 + AutoUnlockTiming.unlockTunnelRetries)
        XCTAssertNil(ladder.unlockedAt, "then the usual climb")
    }
}

final class AutoUnlockRegistryTests: XCTestCase {
    private func entry(_ v: String?) -> RegisteredDevice {
        RegisteredDevice(udid: "U", alias: "phone2", kind: .device, wdaURL: "http://127.0.0.1:8110", state: .down,
                         reason: "locked", autoUnlock: v)
    }

    func testOmittedWhenNilAndEncodedOtherwise() throws {
        let none = String(decoding: try JSONEncoder().encode(entry(nil)), as: UTF8.self)
        XCTAssertFalse(none.contains("auto_unlock"))
        for s in [AutoUnlockState.on, .off, .offAfterFailure] {
            let obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(entry(s.rawValue))) as! [String: Any]
            XCTAssertEqual(obj["auto_unlock"] as? String, s.rawValue)
        }
    }

    func testAnUnknownValueDecodes() throws {
        let json = #"{"udid":"U","alias":"a","kind":"device","wda_url":"x","state":"down","auto_unlock":"maybe"}"#
        let d = try JSONDecoder().decode(RegisteredDevice.self, from: Data(json.utf8))
        XCTAssertEqual(d.autoUnlock, "maybe")
    }
}
