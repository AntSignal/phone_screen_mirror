// Runs the shell suites under scripts/tests, so `swift test` also gates the
// go-ios loopback patch, the pinned go-ios revision, WDA signing and the WDA
// typed-text redaction in the build scripts, and how run.sh and package.sh
// sign the app. Each suite stubs every tool that
// could touch a real keychain, build or Simulator (see its header).

import Foundation
import XCTest
@testable import iMirror

final class ScriptTests: XCTestCase {
    private func runSuite(_ name: String) {
        let repo = URL(fileURLWithPath: #filePath)   // Tests/iMirrorTests/ScriptTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("scripts/tests/\(name)")
        let r = ProcessRunner.spawn("/bin/bash", [script.path])
        XCTAssertEqual(r.code, 0, r.out)
    }

    func testBuildScriptsSuite() { runSuite("test-build-scripts.sh") }
    func testSignScriptsSuite() { runSuite("test-sign-scripts.sh") }
}
