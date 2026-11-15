import Foundation

// HIDKeyboard — the bytes iMirror's Bluetooth keyboard sends. iMirror acts as
// a HID-over-GATT keyboard so it can type into a phone that WDA cannot reach
// (the lock screen, the "Enable UI Automation" sheet). Everything here is
// pure, so the bytes are pinned by tests; BLEKeyboard.swift only moves them.
//
// Sources: USB HID 1.11 (Appendix B.1 boot keyboard), HID Usage Tables
// (page 0x07 Keyboard/Keypad, page 0x08 LEDs), Bluetooth HIDS 1.0, DIS 1.1.

/// One report and how long to wait after sending it.
public struct KeyStep: Equatable, Sendable {
    /// The 8-byte keyboard input report: modifiers, reserved, six keys.
    public var report: [UInt8]
    public var delayAfterMs: Int

    public init(report: [UInt8], delayAfterMs: Int) {
        self.report = report; self.delayAfterMs = delayAfterMs
    }
}

/// A key as the phone sees it: modifier bits plus one usage ID.
public struct KeyStroke: Equatable, Sendable {
    public var modifiers: UInt8
    public var usage: UInt8

    public init(modifiers: UInt8, usage: UInt8) { self.modifiers = modifiers; self.usage = usage }
}

public enum HIDKeyboard {
    /// The one report ID in the report map, for both directions.
    public static let reportID: UInt8 = 1

    /// Left Shift in the modifier byte (usage 0xE1 is bit 1).
    public static let leftShift: UInt8 = 0x02
    public static let returnUsage: UInt8 = 0x28

    /// Keeps a key down long enough for iOS to see it.
    public static let defaultHoldMs = 30
    /// Lets iOS see the release before the next key.
    public static let defaultGapMs = 30

    /// Every key up. Also sent when a phone subscribes, or some hosts stall.
    public static let releaseReport: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]

    /// The HID report map. The boot keyboard layout plus a report ID, so the
    /// Report Reference descriptors have an ID to name. Tests explain each byte.
    public static let reportMap: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x85, reportID,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0,
    ]

    /// HID Information: HID 1.11, no country, remote wake + normally connectable.
    public static let hidInformation: [UInt8] = [0x11, 0x01, 0x00, 0x03]

    /// Report Reference descriptor values: report ID, then type.
    public static let inputReportReference: [UInt8] = [reportID, 0x01]
    public static let outputReportReference: [UInt8] = [reportID, 0x02]

    /// Protocol Mode value for report protocol (0 would be boot).
    public static let reportProtocol: UInt8 = 0x01

    /// PnP ID: USB-IF vendor source, pid.codes' open VID 0x1209, test PID 1, v1.0.
    public static let pnpID: [UInt8] = [0x02, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01]

    /// GAP appearance "Keyboard" (category 0x00F, subcategory 1).
    public static let appearance: UInt16 = 0x03C1

    public static let localName = "iMirror Keyboard"

    /// The key that types `c` on a US layout, or nil when there is none.
    public static func stroke(for c: Character) -> KeyStroke? {
        guard let ascii = c.asciiValue else { return nil }
        if let usage = plain[ascii] { return KeyStroke(modifiers: 0, usage: usage) }
        if let usage = shifted[ascii] { return KeyStroke(modifiers: leftShift, usage: usage) }
        return nil
    }

    /// The report with one key down.
    public static func report(_ k: KeyStroke) -> [UInt8] {
        [k.modifiers, 0, k.usage, 0, 0, 0, 0, 0]
    }

    /// Down, hold, up, gap for each key. A release between keys lets a
    /// doubled letter ("00") register twice.
    public static func sequence(_ keys: [KeyStroke], holdMs: Int = defaultHoldMs,
                                gapMs: Int = defaultGapMs) -> [KeyStep] {
        keys.flatMap { k in
            [KeyStep(report: report(k), delayAfterMs: holdMs),
             KeyStep(report: releaseReport, delayAfterMs: gapMs)]
        }
    }

    /// The strokes for `text`, or nil when one character has no key, so
    /// nothing is ever half-typed.
    public static func strokes(_ text: String) -> [KeyStroke]? {
        var out: [KeyStroke] = []
        for c in text {
            guard let k = stroke(for: c) else { return nil }
            out.append(k)
        }
        return out
    }

    /// The reports that type `text`, or nil when one character has no key.
    public static func textReports(_ text: String, holdMs: Int = defaultHoldMs,
                                   gapMs: Int = defaultGapMs) -> [KeyStep]? {
        strokes(text).map { sequence($0, holdMs: holdMs, gapMs: gapMs) }
    }

    /// Types a passcode, then Return when iOS will not submit it alone.
    /// A 4- or 6-digit code submits itself; a Return after it would land on
    /// whatever screen comes next. A custom code waits for Return (its OK key).
    /// Nil for an empty or untypeable value.
    public static func passcodeReports(_ value: String, holdMs: Int = defaultHoldMs,
                                       gapMs: Int = defaultGapMs) -> [KeyStep]? {
        guard !value.isEmpty, var keys = strokes(value) else { return nil }
        if needsReturn(value) { keys.append(KeyStroke(modifiers: 0, usage: returnUsage)) }
        return sequence(keys, holdMs: holdMs, gapMs: gapMs)
    }

    /// True unless the value is a 4- or 6-digit numeric code.
    public static func needsReturn(_ value: String) -> Bool {
        let allDigits = !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
        return !(allDigits && (value.count == 4 || value.count == 6))
    }

    /// Shift down and up: lights the screen and types nothing.
    public static func wakeReports(holdMs: Int = defaultHoldMs, gapMs: Int = defaultGapMs) -> [KeyStep] {
        [KeyStep(report: [leftShift, 0, 0, 0, 0, 0, 0, 0], delayAfterMs: holdMs),
         KeyStep(report: releaseReport, delayAfterMs: gapMs)]
    }

    /// Test text may only be short lowercase words and digits, so a passcode
    /// (or anything odd) can never be sent through the test path.
    public static func isValidTestText(_ s: String) -> Bool {
        (1...32).contains(s.count) && s.allSatisfy { c in
            c == " " || ("a"..."z").contains(c) || ("0"..."9").contains(c)
        }
    }

    // MARK: - US layout (HID Usage Tables, page 0x07)

    private static let plain: [UInt8: UInt8] = {
        var m: [UInt8: UInt8] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".utf8.enumerated() { m[c] = 0x04 + UInt8(i) }
        for (i, c) in "1234567890".utf8.enumerated() { m[c] = 0x1E + UInt8(i) }
        for (c, u) in zip(" -=[]\\;'`,./".utf8,
                          [0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38] as [UInt8]) {
            m[c] = u
        }
        return m
    }()

    private static let shifted: [UInt8: UInt8] = {
        var m: [UInt8: UInt8] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8.enumerated() { m[c] = 0x04 + UInt8(i) }
        for (i, c) in "!@#$%^&*()".utf8.enumerated() { m[c] = 0x1E + UInt8(i) }
        for (c, u) in zip("_+{}|:\"~<>?".utf8,
                          [0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38] as [UInt8]) {
            m[c] = u
        }
        return m
    }()
}
