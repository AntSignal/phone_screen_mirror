import Foundation

// Typing a passcode held as bytes (SecretBytes), so the value never becomes
// a Swift String that cannot be zeroed. Same keys and Return rule as
// HIDKeyboard.passcodeReports.

extension HIDKeyboard {
    /// Time from the Shift wake to the first Backspace.
    public static let wakeSettleMs = 600

    /// Time for the keypad to slide up after the first Backspace.
    public static let keypadSettleMs = 800

    /// Backspaces after the keypad is up: clears a half-typed code. A long
    /// custom code gets one more than its length, so no leftover survives.
    public static let clearCount = 8

    /// HID usage for Backspace ("Delete" on a Mac keyboard).
    public static let backspaceUsage: UInt8 = 0x2A

    /// The strokes for ASCII bytes, or nil when one byte has no key.
    public static func strokes(ascii: [UInt8]) -> [KeyStroke]? {
        var out: [KeyStroke] = []
        for b in ascii {
            guard b < 0x80, let k = stroke(for: Character(Unicode.Scalar(b))) else { return nil }
            out.append(k)
        }
        return out
    }

    /// `passcodeReports` for bytes: Return only when iOS will not submit alone.
    public static func passcodeReports(ascii: [UInt8], holdMs: Int = defaultHoldMs,
                                       gapMs: Int = defaultGapMs) -> [KeyStep]? {
        guard !ascii.isEmpty, var keys = strokes(ascii: ascii) else { return nil }
        let digits = ascii.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        if !(digits && (ascii.count == 4 || ascii.count == 6)) {
            keys.append(KeyStroke(modifiers: 0, usage: returnUsage))
        }
        return sequence(keys, holdMs: holdMs, gapMs: gapMs)
    }

    /// Shift to wake the phone, Backspaces to open and empty the keypad,
    /// then the passcode. Nil when the passcode is empty or untypeable.
    /// Bug fix (16e, 2026-11-15): Shift lit the screen but the first digit
    /// only opened the keypad, so 3 of 4 digits arrived. Backspace opens
    /// it instead, and deletes nothing when it is already empty.
    public static func wakeThenPasscode(ascii: [UInt8]) -> [KeyStep]? {
        guard let rest = passcodeAfterWake(ascii: ascii) else { return nil }
        return autoWake() + rest
    }

    /// Shift only. Harmless on any screen, so auto-unlock sends it alone
    /// and probes the lock again before any digit goes out.
    public static func wakeOnly() -> [KeyStep] { wakeReports() }

    /// Auto-unlock's wake SEND: Shift, then wakeSettleMs before the SEND
    /// ends, so the screen is up before the reading that approves typing
    /// and the keypad-opening Backspace (the 2026-11-15 timing).
    public static func autoWake() -> [KeyStep] {
        var steps = wakeOnly()
        steps[steps.count - 1].delayAfterMs = wakeSettleMs
        return steps
    }

    /// Backspace to open the keypad, a wait, Backspaces to clear, then the
    /// code. Nil when the code is empty or has a character with no key.
    public static func passcodeAfterWake(ascii: [UInt8]) -> [KeyStep]? {
        guard let code = passcodeReports(ascii: ascii) else { return nil }
        let backspace = KeyStroke(modifiers: 0, usage: backspaceUsage)
        var open = sequence([backspace])
        open[open.count - 1].delayAfterMs = keypadSettleMs
        let clear = sequence(Array(repeating: backspace, count: max(clearCount, ascii.count + 1)))
        return open + clear + code
    }

    /// Zero every report in place once sent: they spell the passcode.
    public static func wipe(_ steps: inout [KeyStep]) {
        for i in steps.indices { SecretsFile.zero(&steps[i].report) }
    }
}
