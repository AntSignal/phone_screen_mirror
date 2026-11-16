import XCTest
@testable import iMirrorCore

final class HIDKeyboardTests: XCTestCase {
    // Golden report map. Each line is one item group, checked against
    // USB HID 1.11 Appendix B.1 (boot keyboard) and HID Usage Tables.
    func testReportMapMatchesTheSpecCheckedGolden() {
        let golden: [UInt8] = [
            // Usage Page (Generic Desktop), Usage (Keyboard), Collection (Application)
            0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
            // Report ID (1): named by both Report Reference descriptors
            0x85, 0x01,
            // Usage Page (Keyboard/Keypad), Usage Min (0xE0 LeftCtrl), Usage Max (0xE7 RightGUI),
            // Logical Min (0), Logical Max (1)
            0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
            // Report Size (1), Report Count (8), Input (Data,Var,Abs): byte 0, modifier bits
            0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
            // Report Count (1), Report Size (8), Input (Const): byte 1, reserved
            0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
            // Report Count (5), Report Size (1), Usage Page (LEDs), Usage Min (1 NumLock),
            // Usage Max (5 Kana), Output (Data,Var,Abs): the LED output report
            0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
            // Report Count (1), Report Size (3), Output (Const): pad LEDs to one byte
            0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
            // Report Count (6), Report Size (8), Logical Min (0), Logical Max (101)
            0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
            // Usage Page (Keyboard/Keypad), Usage Min (0), Usage Max (101),
            // Input (Data,Array,Abs): bytes 2-7, six key slots
            0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
            // End Collection
            0xC0,
        ]
        XCTAssertEqual(HIDKeyboard.reportMap, golden)
    }

    func testReportMapInputBitsAddUpToTheEightByteReport() {
        // modifiers 8x1 + reserved 1x8 + keys 6x8 = 64 bits = 8 bytes.
        XCTAssertEqual(8 * 1 + 1 * 8 + 6 * 8, HIDKeyboard.releaseReport.count * 8)
    }

    func testGattConstantsFollowHIDSAndDIS() {
        // bcdHID 0x0111 little-endian, country 0, flags RemoteWake|NormallyConnectable.
        XCTAssertEqual(HIDKeyboard.hidInformation, [0x11, 0x01, 0x00, 0x03])
        // Report Reference: ID 1, type 1 = Input / 2 = Output.
        XCTAssertEqual(HIDKeyboard.inputReportReference, [0x01, 0x01])
        XCTAssertEqual(HIDKeyboard.outputReportReference, [0x01, 0x02])
        XCTAssertEqual(HIDKeyboard.reportProtocol, 0x01)
        // PnP ID: source 2 (USB-IF), VID 0x1209, PID 0x0001, version 0x0100, all LE.
        XCTAssertEqual(HIDKeyboard.pnpID, [0x02, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01])
        XCTAssertEqual(HIDKeyboard.appearance, 0x03C1)
    }

    func testEveryPrintableASCIICharacterHasAKey() {
        for b in UInt8(0x20)...UInt8(0x7E) {
            let c = Character(UnicodeScalar(b))
            XCTAssertNotNil(HIDKeyboard.stroke(for: c), "no key for \(c)")
        }
    }

    func testKeymapSpotChecksAgainstTheUsageTables() {
        let cases: [(Character, UInt8, UInt8)] = [
            ("a", 0, 0x04), ("z", 0, 0x1D), ("A", 0x02, 0x04), ("Z", 0x02, 0x1D),
            ("1", 0, 0x1E), ("9", 0, 0x26), ("0", 0, 0x27), ("!", 0x02, 0x1E), (")", 0x02, 0x27),
            (" ", 0, 0x2C), ("-", 0, 0x2D), ("_", 0x02, 0x2D), ("=", 0, 0x2E), ("+", 0x02, 0x2E),
            ("[", 0, 0x2F), ("{", 0x02, 0x2F), ("]", 0, 0x30), ("}", 0x02, 0x30),
            ("\\", 0, 0x31), ("|", 0x02, 0x31), (";", 0, 0x33), (":", 0x02, 0x33),
            ("'", 0, 0x34), ("\"", 0x02, 0x34), ("`", 0, 0x35), ("~", 0x02, 0x35),
            (",", 0, 0x36), ("<", 0x02, 0x36), (".", 0, 0x37), (">", 0x02, 0x37),
            ("/", 0, 0x38), ("?", 0x02, 0x38), ("@", 0x02, 0x1F), ("^", 0x02, 0x23),
        ]
        for (c, mods, usage) in cases {
            XCTAssertEqual(HIDKeyboard.stroke(for: c), KeyStroke(modifiers: mods, usage: usage), "\(c)")
        }
    }

    func testNonPrintableAndNonASCIIHaveNoKey() {
        for c: Character in ["\n", "\t", "é", "£", "\u{7F}", "😀"] {
            XCTAssertNil(HIDKeyboard.stroke(for: c))
        }
    }

    func testSequenceIsDownHoldUpGapPerKey() {
        let steps = HIDKeyboard.textReports("aA")!
        XCTAssertEqual(steps, [
            KeyStep(report: [0, 0, 0x04, 0, 0, 0, 0, 0], delayAfterMs: 30),
            KeyStep(report: [0, 0, 0, 0, 0, 0, 0, 0], delayAfterMs: 30),
            KeyStep(report: [0x02, 0, 0x04, 0, 0, 0, 0, 0], delayAfterMs: 30),
            KeyStep(report: [0, 0, 0, 0, 0, 0, 0, 0], delayAfterMs: 30),
        ])
        XCTAssertEqual(HIDKeyboard.textReports("1", holdMs: 50, gapMs: 70)!.map(\.delayAfterMs), [50, 70])
    }

    func testDoubledKeysAreReleasedBetween() {
        let reports = HIDKeyboard.textReports("00")!.map(\.report)
        XCTAssertEqual(reports.map { $0[2] }, [0x27, 0, 0x27, 0])
    }

    func testUntypeableTextGivesNothingRatherThanHalf() {
        XCTAssertNil(HIDKeyboard.textReports("ab\u{e9}c"))
        XCTAssertNil(HIDKeyboard.passcodeReports("12\n34"))
    }

    func testSixAndFourDigitCodesSubmitThemselves() {
        for code in ["123456", "0000"] {
            let usages = HIDKeyboard.passcodeReports(code)!.map { $0.report[2] }
            XCTAssertFalse(usages.contains(HIDKeyboard.returnUsage), code)
            XCTAssertEqual(usages.count, code.count * 2)
        }
    }

    func testAlphanumericAndCustomNumericCodesEndWithReturn() {
        for code in ["abc123", "12345678", "12345"] {
            let steps = HIDKeyboard.passcodeReports(code)!
            XCTAssertEqual(steps.count, (code.count + 1) * 2, code)
            XCTAssertEqual(steps[steps.count - 2].report, [0, 0, 0x28, 0, 0, 0, 0, 0], code)
            XCTAssertEqual(steps.last!.report, HIDKeyboard.releaseReport, code)
        }
    }

    func testEmptyPasscodeTypesNothing() {
        XCTAssertNil(HIDKeyboard.passcodeReports(""))
    }

    func testWakeIsShiftDownUpOnly() {
        let steps = HIDKeyboard.wakeReports()
        XCTAssertEqual(steps.map(\.report), [[0x02, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0]])
        XCTAssertTrue(steps.allSatisfy { $0.report[2...].allSatisfy { $0 == 0 } })
    }

    func testTestTextAllowsOnlyShortLowercaseWordsAndDigits() {
        for ok in ["hello 123", "a", " ", String(repeating: "z", count: 32)] {
            XCTAssertTrue(HIDKeyboard.isValidTestText(ok), ok)
        }
        for bad in ["", "Hello", "a-b", "x\n", String(repeating: "z", count: 33), "caf\u{e9}", "a\u{0301}"] {
            XCTAssertFalse(HIDKeyboard.isValidTestText(bad), bad)
        }    }

    func testTestTextRefusesACombiningMarkThatSortsInsideAToZ() {
        // No precomposed form, so it sorts inside "a"..."z".
        for bad in ["a\u{0332}", "1\u{0332}", "hi a\u{0332}"] {
            XCTAssertFalse(HIDKeyboard.isValidTestText(bad), bad)
            XCTAssertNil(HIDKeyboard.textReports(bad), bad)
        }
    }
}

/// Auto-unlock sends the wake alone, probes the lock, then the rest.
final class PasscodeSplitTests: XCTestCase {
    private let code = Array("222222".utf8)
    private let backspace: [UInt8] = [0, 0, HIDKeyboard.backspaceUsage, 0, 0, 0, 0, 0]

    func testWakeOnlyIsTheWake() {
        XCTAssertEqual(HIDKeyboard.wakeOnly(), HIDKeyboard.wakeReports())
    }

    func testTheTwoHalvesMakeTheClickSequence() throws {
        var wake = HIDKeyboard.wakeOnly()
        wake[wake.count - 1].delayAfterMs = HIDKeyboard.wakeSettleMs
        let rest = try XCTUnwrap(HIDKeyboard.passcodeAfterWake(ascii: code))
        XCTAssertEqual(wake + rest, HIDKeyboard.wakeThenPasscode(ascii: code))
        XCTAssertEqual(HIDKeyboard.autoWake() + rest, HIDKeyboard.wakeThenPasscode(ascii: code))
    }

    /// The auto wake keeps the 600 ms settle, so the approving reading
    /// and the first Backspace come after the screen is up.
    func testTheAutoWakeIsShiftThenTheSettle() {
        let w = HIDKeyboard.autoWake()
        XCTAssertEqual(w.map(\.report), HIDKeyboard.wakeOnly().map(\.report))
        XCTAssertEqual(w.last?.delayAfterMs, HIDKeyboard.wakeSettleMs)
        XCTAssertFalse(w.contains { $0.report[2] == HIDKeyboard.backspaceUsage }, "no key that edits text")
    }

    func testANumericCodeStartsWithBackspaceAndHasNoReturn() throws {
        let steps = try XCTUnwrap(HIDKeyboard.passcodeAfterWake(ascii: code))
        XCTAssertEqual(steps.first?.report, backspace)
        XCTAssertEqual(steps[1].delayAfterMs, HIDKeyboard.keypadSettleMs)
        XCTAssertFalse(steps.contains { $0.report[2] == HIDKeyboard.returnUsage })
    }

    func testACustomCodeEndsWithReturn() throws {
        let steps = try XCTUnwrap(HIDKeyboard.passcodeAfterWake(ascii: Array("abcd12".utf8)))
        XCTAssertEqual(steps[steps.count - 2].report[2], HIDKeyboard.returnUsage)
    }

    func testTheClearCountIsAtLeastEightOrLengthPlusOne() throws {
        func backspaces(_ s: String) throws -> Int {
            try XCTUnwrap(HIDKeyboard.passcodeAfterWake(ascii: Array(s.utf8))).filter { $0.report == backspace }.count
        }
        XCTAssertEqual(try backspaces("2222"), 1 + 8)
        XCTAssertEqual(try backspaces("222222"), 1 + 8)
        XCTAssertEqual(try backspaces("abcdefghij"), 1 + 11)
    }

    func testEmptyOrNonASCIIGivesNothing() {
        XCTAssertNil(HIDKeyboard.passcodeAfterWake(ascii: []))
        XCTAssertNil(HIDKeyboard.passcodeAfterWake(ascii: [0xC3, 0xA9]))
        XCTAssertNil(HIDKeyboard.passcodeAfterWake(ascii: [0x07]))
    }
}
