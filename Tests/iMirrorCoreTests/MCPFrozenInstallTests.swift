// The pure rules of the frozen MCP install: what is copied, how a copy is
// named, the launcher's text, the lease CLI's version line, and pruning.

import Foundation
import XCTest
import iMirrorCore

final class MCPFrozenInstallTests: XCTestCase {
    func testServerFilesExcludeTestsAndConftest() {
        for name in ["imirror_mcp.py", "wda_bringup.py", "devicelease.py", "requirements.txt"] {
            XCTAssertTrue(MCPFrozenInstall.isServerFile(name), name)
        }
        for name in ["test_imirror_mcp.py", "conftest.py", "README.md", "notes.txt",
                     ".hidden.py", "testsupport", "imirror_mcp.pyc"] {
            XCTAssertFalse(MCPFrozenInstall.isServerFile(name), name)
        }
    }

    func testContentHashIsOrderFreeButContentSensitive() {
        let a = ["a.py": Data("x".utf8), "b.py": Data("y".utf8)]
        XCTAssertEqual(MCPFrozenInstall.contentHash(a), MCPFrozenInstall.contentHash(a))
        XCTAssertEqual(MCPFrozenInstall.contentHash(a).count, 64)
        XCTAssertNotEqual(MCPFrozenInstall.contentHash(a),
                          MCPFrozenInstall.contentHash(["a.py": Data("x".utf8), "b.py": Data("z".utf8)]))
        // Moving a byte between files changes the hash.
        XCTAssertNotEqual(MCPFrozenInstall.contentHash(["a.py": Data("xy".utf8), "b.py": Data()]),
                          MCPFrozenInstall.contentHash(["a.py": Data("x".utf8), "b.py": Data("y".utf8)]))
        // So is a renamed file.
        XCTAssertNotEqual(MCPFrozenInstall.contentHash(["a.py": Data("x".utf8)]),
                          MCPFrozenInstall.contentHash(["c.py": Data("x".utf8)]))
    }

    func testVersionDirNameAndItsPattern() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertEqual(MCPFrozenInstall.versionDirName(version: "1.3.0", hash: hash), "1.3.0-abababab")
        XCTAssertEqual(MCPFrozenInstall.versionDirName(version: nil, hash: hash), "unknown-abababab")
        XCTAssertEqual(MCPFrozenInstall.versionDirName(version: "../x y", hash: hash), "unknown-abababab")
        XCTAssertEqual(MCPFrozenInstall.versionDirName(version: "2.0 beta/1", hash: hash), "2.0_beta_1-abababab")
        XCTAssertTrue(MCPFrozenInstall.isVersionDirName("1.3.0-abababab"))
        XCTAssertTrue(MCPFrozenInstall.isVersionDirName("1.3.0-rc1-0123cdef"))
        for name in ["current", ".venv", ".staging-1-abababab", "1.3.0", "1.3.0-ABABABAB",
                     "current.replaced-1760000000"] {
            XCTAssertFalse(MCPFrozenInstall.isVersionDirName(name), name)
        }
    }

    func testServerVersionReadsDunderVersion() {
        XCTAssertEqual(MCPFrozenInstall.serverVersion(in: "x = 1\n__version__ = \"1.3.0\"\n"), "1.3.0")
        XCTAssertEqual(MCPFrozenInstall.serverVersion(in: "__version__='2.0'"), "2.0")
        XCTAssertNil(MCPFrozenInstall.serverVersion(in: "version = '1'"))
    }

    /// Paths contain "Application Support", so quoting is load-bearing.
    func testLauncherScriptText() {
        let text = MCPFrozenInstall.launcherScript(
            venvPython: "/Users/a b/Library/Application Support/iMirror/mcp/.venv/bin/python",
            leaseScript: "/Users/a b/Library/Application Support/iMirror/mcp/current/devicelease.py")
        XCTAssertEqual(text, """
        #!/bin/sh
        # Written by iMirror's MCP installer; rewritten on every install.
        # Runs the device-lease CLI from the frozen copy in mcp/current.
        PY='/Users/a b/Library/Application Support/iMirror/mcp/.venv/bin/python'
        [ -x "$PY" ] || PY='/usr/bin/python3'
        exec "$PY" -I '/Users/a b/Library/Application Support/iMirror/mcp/current/devicelease.py' "$@"

        """)
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(MCPFrozenInstall.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testLeaseProtocolParsesTheJSONLine() {
        XCTAssertEqual(MCPFrozenInstall.leaseProtocol(fromVersionOutput: #"{"version":"1.0.0","protocol":1}"#), 1)
        XCTAssertEqual(MCPFrozenInstall.leaseProtocol(
            fromVersionOutput: "warning: something\n{\"version\":\"2.0.0\",\"protocol\":2}\n"), 2)
        XCTAssertNil(MCPFrozenInstall.leaseProtocol(fromVersionOutput: "imirror-lease 1.0.0"))
        XCTAssertNil(MCPFrozenInstall.leaseProtocol(fromVersionOutput: #"{"version":"1.0.0"}"#))
    }

    func testPruneKeepsNewestThreeCurrentAndRecentCopies() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 3600
        let copies = [
            ("1.0.0-00000001", 100.0), ("1.0.0-00000002", 90.0), ("1.0.0-00000003", 80.0),
            ("1.0.0-00000004", 70.0), ("1.0.0-00000005", 60.0), ("1.0.0-00000006", 50.0),
            ("1.0.0-00000007", 10.0), ("not-a-copy", 100.0),
        ].map { MCPFrozenInstall.InstalledCopy(name: $0.0, installedAt: now - $0.1 * day) }
        let pruned = MCPFrozenInstall.copiesToPrune(copies, current: "1.0.0-00000002", now: now)
        // Newest three: 7, 6, 5. Current: 2. Rest: old.
        XCTAssertEqual(Set(pruned), ["1.0.0-00000001", "1.0.0-00000003", "1.0.0-00000004"])
    }

    func testPruneSparesCopiesYoungerThanThirtyDays() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let copies = (1...6).map {
            MCPFrozenInstall.InstalledCopy(name: "1.0.0-0000000\($0)", installedAt: now - Double($0) * 3600)
        }
        XCTAssertEqual(MCPFrozenInstall.copiesToPrune(copies, current: nil, now: now), [])
    }
}
