// Runs the shell suites under scripts/tests, so `swift test` also gates the
// go-ios loopback patch, the pinned go-ios revision, WDA signing and the WDA
// typed-text redaction in the build scripts, plus the running-bundle guard in
// run.sh / package.sh and diagnose.sh's audits. Each suite stubs every tool
// that could touch a real keychain, build, Simulator or iMirror (see its header).

import Foundation
import XCTest
@testable import iMirror

final class ScriptTests: XCTestCase {
    private func runSuite(_ name: String) {
        let repo = URL(fileURLWithPath: #filePath)   // Tests/iMirrorTests/ScriptTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("scripts/tests/\(name)")
        let r = ProcessRunner.spawn("/bin/bash", [script.path], timeout: 120)
        XCTAssertEqual(r.code, 0, r.out)
    }

    func testBuildScriptsSuite() { runSuite("test-build-scripts.sh") }

    func testAppScriptsSuite() { runSuite("test-app-scripts.sh") }
}
