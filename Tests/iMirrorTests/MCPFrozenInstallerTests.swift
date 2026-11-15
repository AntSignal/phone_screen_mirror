// The frozen MCP install against a temp base directory. The "venv Python" is a
// shell script that logs its arguments, answers pip calls itself (nothing is
// downloaded) and hands every other call to /usr/bin/python3, so the smoke
// test really imports the copied files and really runs devicelease.py.

import Foundation
import XCTest
import iMirrorCore
@testable import iMirror

final class MCPFrozenInstallerTests: XCTestCase {
    private var tmp: URL!
    private var src: URL!
    private var layout: MCPLayout!
    private var log: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = fm.temporaryDirectory.appendingPathComponent("iMirrorTests-frozen-\(UUID().uuidString)",
                                                           isDirectory: true)
        src = tmp.appendingPathComponent("src", isDirectory: true)
        layout = MCPLayout(base: tmp.appendingPathComponent("iMirror", isDirectory: true))
        log = tmp.appendingPathComponent("python.log")
        try fm.createDirectory(at: src.appendingPathComponent("testsupport"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.venvPython.deletingLastPathComponent(), withIntermediateDirectories: true)

        try write("imirror_mcp.py", "__version__ = \"9.9.9\"\nimport wda_bringup\n")
        try write("wda_bringup.py", "READY = True\n")
        try write("requirements.txt", "mcp[cli]>=1.27,<2\n")
        try write("test_imirror_mcp.py", "raise SystemExit('tests must not be copied')\n")
        try write("conftest.py", "raise SystemExit('conftest must not be copied')\n")
        try write("testsupport/fake_wda_server.py", "X = 1\n")
        try write("README.md", "# docs\n")

        let fake = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(MCPFrozenInstall.shellQuote(log.path))
        if [ "$1" = "-m" ] && [ "$2" = "pip" ]; then exit 0; fi
        exec /usr/bin/python3 "$@"

        """
        try Data(fake.utf8).write(to: layout.venvPython)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.venvPython.path)
    }

    override func tearDown() {
        try? fm.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: helpers

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: src.appendingPathComponent(name))
    }

    private func installer(now: Date = Date()) -> MCPFrozenInstaller {
        var i = MCPFrozenInstaller(layout: layout)
        i.now = { now }
        i.smokeTimeout = 30
        return i
    }

    private func leaseScript(protocol proto: Int) -> String {
        """
        import json, sys
        if sys.argv[1:] == ["--version", "--json"]:
            print(json.dumps({"version": "1.0.0", "protocol": \(proto)}))
            sys.exit(0)
        sys.exit(2)

        """
    }

    private func pipRequirementRuns() -> Int {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.hasPrefix("-m pip install --upgrade -r ") }.count
    }

    private func copyDir(_ name: String) -> URL { layout.mcpRoot.appendingPathComponent(name) }

    // MARK: copy rules and naming

    func testInstallCopiesOnlyServerFilesIntoAHashNamedDir() throws {
        let i = installer()
        let outcome = i.install(from: src)
        XCTAssertTrue(outcome.ok, outcome.message)

        let name = try XCTUnwrap(i.currentDirName())
        XCTAssertEqual(outcome.message, name)
        let copied = Set(try fm.contentsOfDirectory(atPath: copyDir(name).path)).subtracting(["__pycache__"])
        XCTAssertEqual(copied, ["imirror_mcp.py", "wda_bringup.py", "requirements.txt"])

        var files: [String: Data] = [:]
        for f in copied { files[f] = try Data(contentsOf: src.appendingPathComponent(f)) }
        let hash8 = String(MCPFrozenInstall.contentHash(files).prefix(8))
        XCTAssertEqual(name, "9.9.9-\(hash8)")
        XCTAssertEqual(i.plannedDirName(sourceDir: src), name)
        XCTAssertTrue(fm.fileExists(atPath: layout.registeredScript.path), "mcp/current/imirror_mcp.py")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: layout.currentLink.path), name)
    }

    func testChangedSourceGetsANewCopyAndKeepsTheOld() throws {
        let i = installer()
        XCTAssertTrue(i.install(from: src).ok)
        let first = try XCTUnwrap(i.currentDirName())

        try write("wda_bringup.py", "READY = 2\n")
        XCTAssertTrue(i.install(from: src).ok)
        let second = try XCTUnwrap(i.currentDirName())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(fm.fileExists(atPath: copyDir(first).path), "old copies are kept")

        // Same files again: same name, nothing new.
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertEqual(i.currentDirName(), second)
    }

    /// Device and sim installs can stage the same copy at once.
    func testConcurrentStagesOfOneCopyAllSucceed() throws {
        let i = installer()
        let files = try i.serverFiles(in: src)
        let name = i.dirName(for: files)
        let lock = NSLock()
        var ok = [Bool](repeating: false, count: 8)
        DispatchQueue.concurrentPerform(iterations: ok.count) { k in
            let staged = (try? i.stage(files, as: name)) != nil
            lock.lock(); ok[k] = staged; lock.unlock()
        }
        XCTAssertEqual(ok, Array(repeating: true, count: 8))
        XCTAssertEqual(try i.serverFiles(in: copyDir(name)), files)
    }

    // MARK: smoke test

    func testFailedImportLeavesCurrentAlone() throws {
        let i = installer()
        XCTAssertTrue(i.install(from: src).ok)
        let good = try XCTUnwrap(i.currentDirName())

        try write("wda_bringup.py", "raise ImportError('half-edited')\n")
        let outcome = i.install(from: src)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("importing imirror_mcp failed"), outcome.message)
        XCTAssertTrue(outcome.message.contains("half-edited"), outcome.message)
        XCTAssertTrue(outcome.message.contains("still runs \(good)"), outcome.message)
        XCTAssertEqual(i.currentDirName(), good)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: layout.currentLink.path), good)
    }

    func testFailedImportOnFirstInstallMakesNoCurrent() throws {
        try write("imirror_mcp.py", "__version__ = \"9.9.9\"\nimport not_shipped\n")
        let outcome = installer().install(from: src)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("has nothing installed"), outcome.message)
        XCTAssertNil(try? fm.attributesOfItem(atPath: layout.currentLink.path))
    }

    func testLeaseProtocolMismatchRefusesTheSwap() throws {
        let i = installer()
        XCTAssertTrue(i.install(from: src).ok)
        let good = try XCTUnwrap(i.currentDirName())

        try write("devicelease.py", leaseScript(protocol: 2))
        let outcome = i.install(from: src)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("protocol 2"), outcome.message)
        XCTAssertEqual(i.currentDirName(), good)
        XCTAssertFalse(fm.fileExists(atPath: layout.leaseLauncher.path))
    }

    // MARK: launcher

    func testLauncherIsWrittenOnlyWhenDeviceLeaseShips() throws {
        let i = installer()
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertFalse(fm.fileExists(atPath: layout.leaseLauncher.path))

        try write("devicelease.py", leaseScript(protocol: 1))
        let outcome = i.install(from: src)
        XCTAssertTrue(outcome.ok, outcome.message)
        let name = try XCTUnwrap(i.currentDirName())
        XCTAssertTrue(fm.fileExists(atPath: copyDir(name).appendingPathComponent("devicelease.py").path))

        let text = try String(contentsOf: layout.leaseLauncher, encoding: .utf8)
        XCTAssertEqual(text, MCPFrozenInstall.launcherScript(
            venvPython: layout.venvPython.path,
            leaseScript: layout.currentLink.appendingPathComponent("devicelease.py").path))
        let mode = try fm.attributesOfItem(atPath: layout.leaseLauncher.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)

        // It runs, from any cwd, through mcp/current.
        let r = ProcessRunner.spawn(layout.leaseLauncher.path, ["--version", "--json"], timeout: 30)
        XCTAssertEqual(r.code, 0, r.out)
        XCTAssertEqual(MCPFrozenInstall.leaseProtocol(fromVersionOutput: r.out), 1)

        // A copy without it removes the launcher.
        try fm.removeItem(at: src.appendingPathComponent("devicelease.py"))
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertFalse(fm.fileExists(atPath: layout.leaseLauncher.path))
    }

    /// The real devicelease.py, not a stand-in: it passes the smoke test, and
    /// the launcher Install writes takes and frees a lease with it. Leases go
    /// to a temp dir, never the live one other sessions use.
    func testTheRealLeaseModuleInstallsAndItsLauncherTakesALease() throws {
        let repo = URL(fileURLWithPath: #filePath)   // Tests/iMirrorTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let real = repo.appendingPathComponent("mcp-server/devicelease.py")
        try fm.copyItem(at: real, to: src.appendingPathComponent("devicelease.py"))
        let outcome = installer().install(from: src)
        XCTAssertTrue(outcome.ok, outcome.message)

        let leases = tmp.appendingPathComponent("leases").path
        let key = "device:00008140-0006423002D3401C"
        let me = String(ProcessInfo.processInfo.processIdentifier)   // in the CLI's chain
        func lease(_ args: [String]) -> (code: Int32, out: String) {
            ProcessRunner.spawn("/usr/bin/env", ["IMIRROR_LEASE_TESTING=1", "IMIRROR_LEASE_DIR=\(leases)",
                                                 layout.leaseLauncher.path] + args + ["--json"],
                                timeout: 30)
        }
        let version = lease(["--version"])
        XCTAssertEqual(version.code, 0, version.out)
        XCTAssertEqual(MCPFrozenInstall.leaseProtocol(fromVersionOutput: version.out), 1)

        let held = lease(["acquire", key, "--anchor-pid", me])
        XCTAssertEqual(held.code, 0, held.out)
        XCTAssertTrue(held.out.contains("\"status\": \"held\""), held.out)
        let status = lease(["status", key])
        XCTAssertTrue(status.out.contains("\"state\": \"covered\""), status.out)
        let released = lease(["release", key, "--anchor-pid", me])
        XCTAssertEqual(released.code, 0, released.out)
        XCTAssertTrue(fm.fileExists(atPath: leases + "/state.json"), "it used the temp dir")
    }

    // MARK: pip

    func testPipRunsOnlyWhenRequirementsChange() throws {
        let i = installer()
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertEqual(pipRequirementRuns(), 1, "a venv with no stored hash gets pip")

        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertEqual(pipRequirementRuns(), 1, "same requirements: no pip")

        try write("wda_bringup.py", "READY = 3\n")
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertEqual(pipRequirementRuns(), 1, "a code change alone: no pip")

        try write("requirements.txt", "mcp[cli]>=1.28,<2\n")
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertEqual(pipRequirementRuns(), 2, "changed requirements: pip again")
    }

    func testFailedSmokeTestMakesTheNextInstallRerunPip() throws {
        let i = installer()
        XCTAssertTrue(i.install(from: src).ok)
        try write("wda_bringup.py", "raise ImportError('x')\n")
        XCTAssertFalse(i.install(from: src).ok)
        try write("wda_bringup.py", "READY = True\n")
        XCTAssertTrue(i.install(from: src).ok)
        XCTAssertEqual(pipRequirementRuns(), 2)
    }

    // MARK: pruning

    func testPruneKeepsTheNewestThreeAndCurrent() throws {
        let i = installer()
        var names: [String] = []
        for n in 1...5 {
            try write("wda_bringup.py", "READY = \(n)\n")
            XCTAssertTrue(i.install(from: src).ok)
            names.append(try XCTUnwrap(i.currentDirName()))
        }
        // Age them a day apart; point current at the oldest.
        let t0 = Date()
        for (k, name) in names.enumerated() {
            try fm.setAttributes([.modificationDate: t0 - Double(5 - k) * 86400],
                                 ofItemAtPath: copyDir(name).path)
        }
        try i.swapCurrent(to: names[0])
        installer(now: t0 + 40 * 86400).prune()

        let left = Set(try fm.contentsOfDirectory(atPath: layout.mcpRoot.path))
        XCTAssertTrue(left.isSuperset(of: [names[0], names[2], names[3], names[4], "current", ".venv"]))
        XCTAssertFalse(left.contains(names[1]))
    }
}

final class MCPInstallerStatusTests: XCTestCase {
    func testCopyIsCurrentNeedsAnInstalledCopyThatMatches() {
        XCTAssertFalse(MCPInstaller.copyIsCurrent(installed: nil, wanted: "1-aaaaaaaa"))
        XCTAssertFalse(MCPInstaller.copyIsCurrent(installed: nil, wanted: nil))
        XCTAssertTrue(MCPInstaller.copyIsCurrent(installed: "1-aaaaaaaa", wanted: "1-aaaaaaaa"))
        XCTAssertFalse(MCPInstaller.copyIsCurrent(installed: "1-aaaaaaaa", wanted: "1-bbbbbbbb"))
        XCTAssertTrue(MCPInstaller.copyIsCurrent(installed: "1-aaaaaaaa", wanted: nil))
    }
}

final class ProcessRunnerTimeoutTests: XCTestCase {
    func testTimeoutStopsAHungChild() {
        let start = Date()
        let r = ProcessRunner.spawn("/bin/sleep", ["20"], timeout: 0.3)
        XCTAssertNotEqual(r.code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
