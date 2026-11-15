// Only a person's click may type a passcode. These tests read the app's
// source and fail if anything else starts that path: a timer, a request
// file or an MCP call that typed a passcode could burn a phone's attempts.

import AppKit
import XCTest
@testable import iMirror

final class PasscodeCallSiteTests: XCTestCase {
    private func sources() throws -> [(name: String, text: String)] {
        let repo = URL(fileURLWithPath: #filePath)   // Tests/iMirrorTests/PasscodeCallSiteTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testOnlyTheButtonActionTypesAPasscode() throws {
        var defs: [String] = [], calls: [String] = []
        for (name, text) in try sources() {
            defs += Array(repeating: name, count: count("func typePasscodeFromClick(", in: text))
            calls += Array(repeating: name, count: count("typePasscodeFromClick(", in: text)
                           - count("func typePasscodeFromClick(", in: text))
        }
        XCTAssertEqual(defs, ["KeyboardControl.swift"])
        XCTAssertEqual(calls, ["main.swift"], "one call, from the button's action")

        let main = try XCTUnwrap(try sources().first { $0.name == "main.swift" }?.text)
        let action = try XCTUnwrap(main.range(of: "@objc private func typePasscodeClicked(_ sender: NSButton)"))
        let call = try XCTUnwrap(main.range(of: "typePasscodeFromClick("))
        XCTAssertLessThan(action.upperBound, call.lowerBound)
        let between = main[action.upperBound..<call.lowerBound]
        XCTAssertFalse(between.contains("func "), "the call sits inside the action itself")
        // Nothing calls the action directly; only the button names it.
        XCTAssertEqual(count("typePasscodeClicked", in: main), 2)
        XCTAssertEqual(count("#selector(typePasscodeClicked(_:))", in: main), 1)
    }

    func testThePasscodeIsReadInOnePlaceOnly() throws {
        let hits = try sources().filter { $0.text.contains("PasscodeLookup.load(") }.map(\.name)
        XCTAssertEqual(hits, ["KeyboardControl.swift"])
        let load = try sources().filter { $0.text.contains("PasscodeLookup.value(") && $0.name != "SecretsFile.swift" }
        XCTAssertEqual(load.map(\.name), [])
    }

    func testOnlyAPersonsEventCounts() {
        XCTAssertTrue(KeyboardControl.isHumanClick(.leftMouseUp))
        XCTAssertTrue(KeyboardControl.isHumanClick(.keyDown))
        XCTAssertFalse(KeyboardControl.isHumanClick(nil))
        XCTAssertFalse(KeyboardControl.isHumanClick(.appKitDefined))
        XCTAssertFalse(KeyboardControl.isHumanClick(.periodic))
    }
}
