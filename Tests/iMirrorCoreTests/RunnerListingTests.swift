import XCTest
@testable import iMirrorCore

private let phone3 = "00008020-000324610A68002E"

/// A failed `apps --list` used to read as "not installed", so a tunnel
/// restart could reinstall the runner on every phone.
final class RunnerListingTests: XCTestCase {
    func testAFailedListingKeepsTheRunner() {
        XCTAssertEqual(runnerAction(listing: .failed, bundled: "11.1.0"), .keep)
        XCTAssertEqual(runnerAction(listing: .failed, bundled: nil), .keep)
    }

    func testAListingThatWorksDecidesAsBefore() {
        XCTAssertEqual(runnerAction(listing: .listed(version: nil), bundled: "11.1.0"), .install)
        XCTAssertEqual(runnerAction(listing: .listed(version: "10.0.0"), bundled: "11.1.0"), .upgrade)
        XCTAssertEqual(runnerAction(listing: .listed(version: "11.1.0"), bundled: "11.1.0"), .keep)
        XCTAssertEqual(runnerAction(listing: .listed(version: "10.0.0"), bundled: "11.1.0",
                                    failedUpgradeTo: "11.1.0"), .keep)
    }

    func testOneRetryBeforeGivingUpOnTheListing() {
        XCTAssertEqual(RunnerListingPolicy.retries, 1)
    }

    /// No ipa in the build: only a listing that worked and shows no runner
    /// is "missing". A failed one still lets runwda try.
    func testNoBundleOutcome() {
        XCTAssertEqual(noBundleOutcome(.listed(version: nil)), .missing)
        XCTAssertEqual(noBundleOutcome(.listed(version: "11.1.0")), .noBundle)
        XCTAssertEqual(noBundleOutcome(.listed(version: "")), .noBundle)
        XCTAssertEqual(noBundleOutcome(.failed), .noBundle)
    }

    func testAMissingRunnerNeverSpawnsRunwda() {
        XCTAssertFalse(shouldSpawnRunwda(after: .missing))
    }

    func testTheMessageNamesTheCommandsForThisPhone() {
        let m = runnerMissingMessage(alias: "phone3", udid: phone3)
        XCTAssertTrue(m.contains("DEVELOPMENT_TEAM=<team> WDA_DESTINATION=\"id=\(phone3)\" ./scripts/build-wda.sh"))
        XCTAssertTrue(m.contains("tools/go-ios/bin/ios install --udid=\(phone3) --path=build/WebDriverAgent.ipa"))
        XCTAssertTrue(m.contains("every 30 s"))
    }

    /// A missing runner is a person's job: its own reason, ahead of the
    /// generic ones, and it never keeps the Mac awake.
    func testRunnerMissingReason() {
        let i = DeviceReasonInputs(ready: false, tunnelHasDevice: false, restarting: true,
                                   everConnected: true, locked: true, runnerMissing: true)
        XCTAssertEqual(deviceReason(i), .runnerMissing)
        XCTAssertNil(deviceReason(DeviceReasonInputs(ready: true, runnerMissing: true)))
        XCTAssertFalse(SleepPolicy.isRecovering(.runnerMissing, gaveUp: false))
    }

    /// The same file the MCP server and antsignalctl lock.
    func testInstallLockFile() {
        XCTAssertEqual(InstallLockPolicy.fileName, "devicectl.lock")
        XCTAssertGreaterThan(InstallLockPolicy.waitSec, 60)
    }
}
