import XCTest
@testable import iMirrorCore

// Every value here is a dummy. Real secrets files are never read by tests.
final class SecretsFileTests: XCTestCase {
    private func value(_ key: String, _ text: String) -> String? {
        SecretsFile.value(forKey: key, in: Array(text.utf8)).map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    func testPlainExportAndSpacedLines() {
        let text = "A=1\nexport B=two\n  C = three  \nexport\tD=4\n"
        XCTAssertEqual(value("A", text), "1")
        XCTAssertEqual(value("B", text), "two")
        XCTAssertEqual(value("C", text), "three")
        XCTAssertEqual(value("D", text), "4")
    }

    func testQuotes() {
        let text = #"""
        D="a b # not a comment"
        S='it\s "raw"'
        E="say \"hi\" \\ ok" # trailing
        """#
        XCTAssertEqual(value("D", text), "a b # not a comment")
        XCTAssertEqual(value("S", text), #"it\s "raw""#)
        XCTAssertEqual(value("E", text), #"say "hi" \ ok"#)
    }

    func testCommentsAndCRLF() {
        let text = "# K=commented\nK=5 # note\r\nL=x#y\r\n"
        XCTAssertEqual(value("K", text), "5")
        XCTAssertEqual(value("L", text), "x#y", "a # with no space before is part of the value")
    }

    func testOnlyTheExactKeyMatches() {
        let text = "KEY_LONGER=1\nXKEY=2\nkey=3\n"
        XCTAssertNil(value("KEY", text))
    }

    func testMissingEmptyOrUnclosedIsNil() {
        XCTAssertNil(value("A", "B=1\n"))
        XCTAssertNil(value("A", "A=\n"))
        XCTAssertNil(value("A", "A=\"\"\n"))
        XCTAssertNil(value("A", "A=\"open\n"))
        XCTAssertNil(value("A", "A\n"))
        XCTAssertNil(value("A", ""))
    }

    func testTheLastLineWinsAsInAShell() {
        XCTAssertEqual(value("A", "A=1\nA=2\n"), "2")
    }

    func testASecretNeverPrintsItsValue() {
        let s = SecretBytes(Array("424242".utf8))
        for text in ["\(s)", String(reflecting: s), String(describing: s)] {
            XCTAssertFalse(text.contains("4242"), text)
            XCTAssertTrue(text.contains("6"), text)
        }
        var dumped = ""
        dump(s, to: &dumped)
        XCTAssertFalse(dumped.contains("4242"), dumped)
    }

    func testWipeZeroesAndEmpties() {
        let s = SecretBytes([1, 2, 3])
        s.wipe()
        XCTAssertEqual(s.count, 0)
        var a: [UInt8] = [9, 9]
        SecretsFile.zero(&a)
        XCTAssertEqual(a, [0, 0])
    }
}

final class PasscodeLookupTests: XCTestCase {
    private let udid = "00008140-0006423002D3401C"
    private let other = "00008150-001928E01404401C"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imirror-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ text: String) -> URL {
        let url = dir.appendingPathComponent(".env.local")
        try! Data(text.utf8).write(to: url)
        return url
    }

    private func load(_ udid: String, _ url: URL) -> String? {
        if case .found(let s) = PasscodeLookup.load(udid: udid, file: url) {
            return String(decoding: s.bytes, as: UTF8.self)
        }
        return nil
    }

    func testTheKeyIsTheUDIDWithoutDashes() {
        XCTAssertEqual(PasscodeLookup.key(udid: "00008140-0006423002d3401c"), "IMIRROR_PASSCODE_000081400006423002D3401C")
    }

    func testThePhonesOwnKeyComesFirst() {
        let url = file("""
        ANTSIGNAL_DEVICE_UDID=\(udid)
        ANTSIGNAL_TEST_DEVICE_PASSCODE=111111
        IMIRROR_PASSCODE_000081400006423002D3401C=222222
        """)
        XCTAssertEqual(load(udid, url), "222222")
    }

    func testTheSharedKeyOnlyForItsOwnPhone() {
        let url = file("export ANTSIGNAL_DEVICE_UDID=\"\(udid.lowercased())\"\nANTSIGNAL_TEST_DEVICE_PASSCODE=111111\n")
        XCTAssertEqual(load(udid, url), "111111")
        guard case .noPasscode = PasscodeLookup.load(udid: other, file: url) else {
            return XCTFail("another phone must never get this passcode")
        }
    }

    func testNoOwnerMeansNoSharedKey() {
        guard case .noPasscode = PasscodeLookup.load(udid: udid, file: file("ANTSIGNAL_TEST_DEVICE_PASSCODE=111111\n"))
        else { return XCTFail("no owner line") }
    }

    func testMissingFileOrEmptyValue() {
        guard case .noFile = PasscodeLookup.load(udid: udid, file: dir.appendingPathComponent("absent")) else {
            return XCTFail("missing file")
        }
        guard case .noPasscode = PasscodeLookup.load(udid: udid, file: file("IMIRROR_PASSCODE_000081400006423002D3401C=\n"))
        else { return XCTFail("empty value") }
    }

    func testTheFilePathDefaultsAndExpandsTilde() {
        XCTAssertTrue(PasscodeFile.url(stored: nil).path.hasSuffix("/Purpose-iOS/Testing/.env.local"))
        XCTAssertFalse(PasscodeFile.url(stored: "  ").path.contains("~"))
        XCTAssertEqual(PasscodeFile.url(stored: "/tmp/x.env").path, "/tmp/x.env")
        XCTAssertEqual(PasscodeFile.url(stored: "~/a").path, NSHomeDirectory() + "/a")
    }
}

final class PasscodeTypingTests: XCTestCase {
    func testBytesTypeLikeTheStringVersion() {
        for code in ["123456", "1234", "12345678", "abc1", "Pass word!"] {
            XCTAssertEqual(HIDKeyboard.passcodeReports(ascii: Array(code.utf8)), HIDKeyboard.passcodeReports(code), code)
        }
        XCTAssertNil(HIDKeyboard.passcodeReports(ascii: []))
        XCTAssertNil(HIDKeyboard.passcodeReports(ascii: [0xC3, 0xA9]), "é has no key")
        XCTAssertNil(HIDKeyboard.passcodeReports(ascii: [0x0A]), "no key for a newline")
    }

    func testWakeThenAPauseThenTheCode() throws {
        let steps = try XCTUnwrap(HIDKeyboard.wakeThenPasscode(ascii: Array("123456".utf8)))
        XCTAssertEqual(steps[0].report, [HIDKeyboard.leftShift, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(steps[1].report, HIDKeyboard.releaseReport)
        XCTAssertEqual(steps[1].delayAfterMs, 600)
        XCTAssertEqual(Array(steps.dropFirst(2)), HIDKeyboard.passcodeReports("123456"))
        XCTAssertNil(HIDKeyboard.wakeThenPasscode(ascii: []))
    }

    func testWipeZeroesEveryReport() throws {
        var steps = try XCTUnwrap(HIDKeyboard.wakeThenPasscode(ascii: Array("9876".utf8)))
        HIDKeyboard.wipe(&steps)
        XCTAssertTrue(steps.allSatisfy { $0.report == [0, 0, 0, 0, 0, 0, 0, 0] })
    }
}
