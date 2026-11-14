// Upstream's TransportLifecycleTests (fed3fb9), ported to the per-phone
// DeviceChain: a stop or restart must silence everything the replaced
// bring-up still had queued — children it would spawn, and the install
// events it would report.

import XCTest
import iMirrorCore
@testable import iMirror

final class DeviceChainLifecycleTests: XCTestCase {
    private var root: URL!
    private var marker: URL!
    private var chain: DeviceChain?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirror-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        marker = root.appendingPathComponent("spawned")
    }

    override func tearDown() {
        chain?.stop()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A chain whose go-ios is a script that only leaves a marker. Its
    /// slot's ports are far from any real phone's (8100, 8110, …).
    private func makeChain(startup: DispatchQueue) throws -> DeviceChain {
        let bin = root.appendingPathComponent("fake-ios")
        try "#!/bin/sh\ntouch '\(marker.path)'\nsleep 30\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let slot = PortSlot(470)
        for port in slot.ports { XCTAssertTrue(ChainManager.portIsFree(port), "port \(port) in use") }
        let c = DeviceChain(udid: "TEST-UDID", slot: slot, bin: bin, workDir: root, startupQueue: startup)
        c.tunnelHasDevice = { true }
        chain = c
        return c
    }

    private func drainMain() {
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
    }

    func testStopCancelsAQueuedBringUp() throws {
        let startup = DispatchQueue(label: "test.chain.startup")
        startup.suspend()
        let chain = try makeChain(startup: startup)
        chain.start()
        chain.stopChildren()
        startup.resume()
        startup.sync {}
        drainMain()
        XCTAssertFalse(chain.hasChildHandlesForTesting, "a stopped chain launched runwda")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The bring-up finished its checks and queued its results on main;
    /// then the chain was stopped. Upstream found this let a replaced
    /// bring-up report "install failed" against a fresh chain.
    func testAStopAfterTheChecksDropsTheirEventsAndSpawnsNothing() throws {
        let startup = DispatchQueue(label: "test.chain.startup-completion")
        let chain = try makeChain(startup: startup)
        var events: [RunnerInstallEvent] = []
        chain.onRunnerInstall = { events.append($0) }
        chain.start()
        startup.sync {}                 // checks done; results wait on main
        chain.stopChildren()
        drainMain()
        XCTAssertEqual(events, [], "a replaced bring-up's install events reached the UI")
        XCTAssertFalse(chain.hasChildHandlesForTesting)
    }

    /// The same bring-up, left alone, does report and spawn: the test
    /// above is not passing because nothing ever runs.
    func testAnUninterruptedBringUpReportsAndSpawns() throws {
        let startup = DispatchQueue(label: "test.chain.startup-control")
        let chain = try makeChain(startup: startup)
        var events: [RunnerInstallEvent] = []
        chain.onRunnerInstall = { events.append($0) }
        chain.start()
        startup.sync {}
        drainMain()
        XCTAssertEqual(events, [.checking, .done(.noBundle)])   // the test bundle has no ipa
        XCTAssertTrue(chain.hasChildHandlesForTesting)
    }
}
