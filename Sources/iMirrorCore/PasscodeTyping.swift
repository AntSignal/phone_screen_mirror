import Foundation

// Typing a passcode held as bytes (SecretBytes), so the value never becomes
// a Swift String that cannot be zeroed. Same keys and Return rule as
// HIDKeyboard.passcodeReports.

extension HIDKeyboard {
    /// Time from the Shift wake to the first digit, so the lock screen's
    /// keypad is up before typing starts.
    public static let wakeSettleMs = 600

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

    /// Shift to wake the phone, a pause, then the passcode. Nil when the
    /// passcode is empty or has a byte with no key.
    public static func wakeThenPasscode(ascii: [UInt8]) -> [KeyStep]? {
        guard let code = passcodeReports(ascii: ascii) else { return nil }
        var steps = wakeReports()
        steps[steps.count - 1].delayAfterMs = wakeSettleMs
        return steps + code
    }

    /// Zero every report in place once sent: they spell the passcode.
    public static func wipe(_ steps: inout [KeyStep]) {
        for i in steps.indices { SecretsFile.zero(&steps[i].report) }
    }
}
