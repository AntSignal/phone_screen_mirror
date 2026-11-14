// Runs scripts/tests/test-app-scripts.sh, so `swift test` also gates the
// running-bundle guard in run.sh / package.sh and diagnose.sh's audits. The
// script stubs every tool that could touch a real iMirror (see its header).

import Foundation
import XCTest
@testable import iMirror

final class ScriptTests: XCTestCase {
    func testAppScriptsSuite() throws {
        let repo = URL(fileURLWithPath: #filePath)   // Tests/iMirrorTests/ScriptTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("scripts/tests/test-app-scripts.sh")
        let r = ProcessRunner.spawn("/bin/bash", [script.path], timeout: 120)
        XCTAssertEqual(r.code, 0, r.out)
    }
}
