import Foundation

// DongleProtocol — the text lines iMirror and its ESP32-S3 keyboard dongle
// trade over USB serial (protocol v1). The dongle is a Bluetooth keyboard
// with its own address, so a phone on this Mac's iCloud account does not
// hide it as "my Mac". The README's "Keyboard dongle" section is the
// contract; device-firmware's esp32-s3/BLE_KEYBOARD_DONGLE.md is the other
// side. Pure, so tests pin every byte.
//
// A SEND line carries key reports, which may spell a passcode. Its bytes
// are [UInt8] so the caller can zero them, and its description is redacted.

/// One command, host to dongle.
public enum DongleCommand: Equatable, Sendable, CustomStringConvertible {
    case hello, status, bonds, disconnect
    case pair(slot: String, seconds: Int)
    case forget(slot: String)
    /// 1...128 steps, as checked by DongleProtocol.sendChunks.
    case send(slot: String, steps: [KeyStep])

    /// The full line, "\n" included. Zero it after writing when it is a SEND.
    public var line: [UInt8] {
        var out: [UInt8]
        switch self {
        case .hello: out = Array("HELLO".utf8)
        case .status: out = Array("STATUS".utf8)
        case .bonds: out = Array("BONDS".utf8)
        case .disconnect: out = Array("DISCONNECT".utf8)
        case .pair(let slot, let seconds): out = Array("PAIR \(slot) \(seconds)".utf8)
        case .forget(let slot): out = Array("FORGET \(slot)".utf8)
        case .send(let slot, let steps):
            out = Array("SEND \(slot) ".utf8)
            DongleProtocol.appendHex(steps, to: &out)
        }
        out.append(0x0A)
        return out
    }

    /// Safe to log: a SEND shows its step count, never its bytes.
    public var description: String {
        switch self {
        case .send(let slot, let steps): return "SEND \(slot) <\(steps.count) steps>"
        default: return String(decoding: line.dropLast(), as: UTF8.self)
        }
    }

    /// The word an OK reply to this command must carry.
    public var okWord: String {
        switch self {
        case .hello: return "HELLO"
        case .status: return "STATUS"
        case .bonds: return "BONDS"
        case .disconnect: return "DISCONNECTED"
        case .pair: return "PAIRED"
        case .forget: return "FORGOT"
        case .send: return "SENT"
        }
    }
}

/// One line, dongle to host.
public enum DongleLine: Equatable, Sendable {
    /// "# ..." log text. Never holds reports or typed text.
    case log(String)
    case bond(slot: String, peer: String)
    case ok(word: String, args: [String])
    case err(code: String)
    /// Anything else; skipped.
    case other
}

/// A command's whole answer: its final line and any BOND lines before it.
public struct DongleReply: Equatable, Sendable {
    public enum Final: Equatable, Sendable {
        case ok(word: String, args: [String])
        case err(code: String)
    }
    public var final: Final
    public var bonds: [DongleBond]

    public init(final: Final, bonds: [DongleBond] = []) { self.final = final; self.bonds = bonds }
}

public struct DongleBond: Equatable, Sendable {
    public var slot: String
    public var peer: String
}

/// What the dongle said HELLO with.
public struct DongleHello: Equatable, Sendable {
    public var version: Int
    public var address: String
}

public enum DongleProtocol {
    public static let name = "imirror-kbd"
    public static let version = 1
    /// USB vendor id of every Espressif chip, the S3's built-in port included.
    public static let vendorID = 0x303A
    public static let maxSteps = 128
    public static let maxDelayMs = 2000
    public static let pairSeconds = 10...600
    /// Longer lines are noise, not protocol; dropped.
    public static let maxLineBytes = 512

    // Timeouts for a whole command, from write to final line.
    public static let helloTimeoutSec: TimeInterval = 2
    public static let sendTimeoutSec: TimeInterval = 30
    public static let otherTimeoutSec: TimeInterval = 5
    /// PAIR waits its window plus this.
    public static let pairGraceSec: TimeInterval = 10

    /// A SEND's own delays can pass 30 s (128 steps of up to 2 s), so it
    /// gets the dongle's 15 s connect wait, 1 s settle and its delays, plus slack.
    public static func timeout(for c: DongleCommand) -> TimeInterval {
        switch c {
        case .hello: return helloTimeoutSec
        case .send(_, let steps):
            let delays = TimeInterval(steps.reduce(0) { $0 + max($1.delayAfterMs, 0) }) / 1000
            return max(sendTimeoutSec, 15 + 1 + delays + 4)
        case .pair(_, let s): return TimeInterval(s) + pairGraceSec
        default: return otherTimeoutSec
        }
    }

    // MARK: - Slots

    public static func isValidSlot(_ s: String) -> Bool {
        (1...32).contains(s.utf8.count) && s.utf8.allSatisfy { b in
            (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == 0x2D
        }
    }

    /// A phone's slot: its UDID lower-cased, dashes dropped. A 40-character
    /// UDID (older phones) keeps its first 32. Nil when it is not a UDID.
    public static func slot(udid: String) -> String? {
        guard ExpectedReset.fileName(udid: udid) != nil else { return nil }
        let s = String(udid.lowercased().filter { $0 != "-" }.prefix(32))
        return isValidSlot(s) ? s : nil
    }

    // MARK: - SEND framing

    /// Splits steps into SEND-sized pieces of at most `maxSteps`. A piece
    /// ends after a key-up report when it can, since the dongle disconnects
    /// between SENDs. Nil when a report is not 8 bytes or a delay is out of
    /// range, so nothing is half-sent.
    public static func sendChunks(_ steps: [KeyStep], max: Int = maxSteps) -> [[KeyStep]]? {
        guard !steps.isEmpty, max > 0, steps.allSatisfy({
            $0.report.count == 8 && (0...maxDelayMs).contains($0.delayAfterMs)
        }) else { return nil }
        var out: [[KeyStep]] = []
        var start = 0
        while start < steps.count {
            var end = min(start + max, steps.count)
            if end < steps.count,
               let lastUp = (start..<end).last(where: { steps[$0].report == HIDKeyboard.releaseReport }) {
                end = lastUp + 1
            }
            out.append(Array(steps[start..<end]))
            start = end
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// 10 bytes per step, as lower-case hex: the report, then the delay
    /// as two big-endian bytes.
    static func appendHex(_ steps: [KeyStep], to out: inout [UInt8]) {
        out.reserveCapacity(out.count + steps.count * 20)
        func put(_ b: UInt8) {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0F)])
        }
        for s in steps {
            // No joined temp array: it would be one more passcode copy.
            for b in s.report { put(b) }
            let d = UInt16(clamping: s.delayAfterMs)
            put(UInt8(d >> 8))
            put(UInt8(d & 0xFF))
        }
    }

    // MARK: - Replies

    /// One line, "\r" and "\n" already stripped.
    public static func parse(_ line: String) -> DongleLine {
        if line.hasPrefix("#") { return .log(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return .other }
        switch head {
        case "OK" where parts.count >= 2:
            return .ok(word: parts[1], args: Array(parts.dropFirst(2)))
        case "ERR" where parts.count >= 2:
            return .err(code: parts[1])
        case "BOND" where parts.count == 3:
            guard isValidSlot(parts[1]), let peer = address(parts[2]) else { return .other }
            return .bond(slot: parts[1], peer: peer)
        default:
            return .other
        }
    }

    /// A Bluetooth address as six lower-case hex pairs, or nil.
    public static func address(_ s: String) -> String? {
        let parts = s.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            return nil
        }
        return parts.joined(separator: ":")
    }

    /// The HELLO answer, or nil when it is not a v1 iMirror dongle (some
    /// other ESP32 on USB answers anything else, or nothing).
    public static func hello(_ r: DongleReply) -> DongleHello? {
        guard case .ok("HELLO", let a) = r.final, a.count == 3, a[0] == name,
              let v = Int(a[1]), v == version, let addr = address(a[2]) else { return nil }
        return DongleHello(version: v, address: addr)
    }

    /// The peer address from "OK PAIRED <slot> <peer>" for `slot`.
    public static func pairedPeer(_ r: DongleReply, slot: String) -> String? {
        guard case .ok("PAIRED", let a) = r.final, a.count == 2, a[0] == slot else { return nil }
        return address(a[1])
    }

    /// A PAIR reply as a pairing outcome; nil means use `failure(_:)`.
    /// The dongle refuses two new phones itself, so "ambiguous" is two.
    public static func pairOutcome(_ r: DongleReply, slot: String) -> PairingOutcome? {
        if let peer = pairedPeer(r, slot: slot) { return .paired(central: peer) }
        switch r.final {
        case .err("AMBIGUOUS"): return .ambiguous(count: 2)
        // Spelled out: a bare .none here would be Optional.none.
        case .err("TIMEOUT"): return PairingOutcome.none
        default: return nil
        }
    }

    /// True when a SEND of `steps` steps went out whole.
    public static func sent(_ r: DongleReply, steps: Int) -> Bool {
        r.final == .ok(word: "SENT", args: [String(steps)])
    }

    /// True when the slot is gone; an unknown slot is already gone.
    public static func forgot(_ r: DongleReply, slot: String) -> Bool {
        r.final == .ok(word: "FORGOT", args: [slot]) || r.final == .err(code: "UNKNOWN_SLOT")
    }

    /// Why a reply is not the success its command wanted.
    public static func failure(_ r: DongleReply) -> KeyboardFailure {
        switch r.final {
        case .err("BUSY"): return .busy
        case .err("NOT_CONNECTED"): return .notConnected
        // The dongle has no bond for this phone any more.
        case .err("UNKNOWN_SLOT"): return .notPaired
        default: return .dongleError
        }
    }
}

/// Collects one command's reply line by line. Lines from a reply that is
/// not this command's (an OK for another word) are skipped, so a late
/// answer to a timed-out command cannot answer the next one.
public struct DongleReplyReader: Sendable {
    public let expecting: String
    private var bonds: [DongleBond] = []
    private var buffer: [UInt8] = []
    private var dropping = false

    public init(for command: DongleCommand) { expecting = command.okWord }

    /// Feeds raw bytes. Returns the reply once its final line has come,
    /// and the log lines seen (for the caller to log).
    public mutating func feed(_ bytes: [UInt8]) -> (reply: DongleReply?, logs: [String]) {
        var logs: [String] = []
        for b in bytes {
            guard b == 0x0A else {
                if buffer.count >= DongleProtocol.maxLineBytes { dropping = true; buffer = [] }
                if !dropping { buffer.append(b) }
                continue
            }
            defer { buffer = []; dropping = false }
            guard !dropping else { continue }
            if buffer.last == 0x0D { buffer.removeLast() }
            switch DongleProtocol.parse(String(decoding: buffer, as: UTF8.self)) {
            case .log(let text): logs.append(text)
            case .bond(let slot, let peer): bonds.append(DongleBond(slot: slot, peer: peer))
            case .ok(let word, let args) where word == expecting:
                return (DongleReply(final: .ok(word: word, args: args), bonds: bonds), logs)
            case .err(let code):
                return (DongleReply(final: .err(code: code), bonds: bonds), logs)
            case .ok, .other:
                bonds = []
            }
        }
        return (nil, logs)
    }
}
