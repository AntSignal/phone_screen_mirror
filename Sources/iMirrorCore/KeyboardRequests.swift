import Foundation

// Keyboard requests: a client (scripts/imirror-ctl) writes
// requests/keyboard-<udid>.json, and the app pairs, tests or forgets the
// Bluetooth keyboard for that phone. The README's "Files other tools read"
// is the contract. A file can be written by anyone who can write the folder,
// so a file can turn auto-unlock on or off, never carry or type a passcode.

public enum KeyboardAction: String, Sendable, CaseIterable {
    /// Open a pairing window for this phone.
    case pair
    /// Drop this phone's central from keyboard-pairs.json.
    case forget
    /// Type harmless test text into this phone.
    case test
    /// Let iMirror type this phone's passcode when it finds it locked.
    case autoOn = "auto_on"
    /// Stop that. Always allowed.
    case autoOff = "auto_off"
}

public struct KeyboardRequest: Equatable, Sendable {
    public var udid: String
    public var requestedAt: Date
    /// Who asked, for the log only; clipped.
    public var requestedBy: String
    public var action: KeyboardAction
    /// `test` only; always passes `isAllowedTestText`.
    public var text: String?

    public init(udid: String, requestedAt: Date, requestedBy: String, action: KeyboardAction, text: String? = nil) {
        self.udid = udid; self.requestedAt = requestedAt; self.requestedBy = requestedBy
        self.action = action; self.text = text
    }
}

/// Why a keyboard request or run did nothing. Logged as the keyboard
/// event's `reason`, so these names are part of the README contract.
public enum KeyboardFailure: String, Sendable {
    case badRequest = "bad_request"
    case unknownAction = "unknown_action"
    case badText = "bad_text"
    case stale
    case notAttached = "not_attached"
    case notPaired = "not_paired"
    case busy
    case bluetoothUnavailable = "bluetooth_unavailable"
    case setupFailed = "setup_failed"
    case notConnected = "not_connected"
    case sendFailed = "send_failed"
    /// Click-to-type: the secrets file is missing or unreadable.
    case noFile = "no_file"
    /// Click-to-type: the file has no passcode for this phone.
    case noPasscode = "no_passcode"
    /// Click-to-type: a character in the passcode has no key.
    case untypeable
    /// The phone is paired with the dongle, and no dongle answers on USB.
    case dongleUnavailable = "dongle_unavailable"
    /// The dongle gave no answer in time, or one iMirror cannot read.
    case dongleError = "dongle_error"
}

public enum KeyboardRequestFile {
    public enum Read: Equatable, Sendable {
        case request(KeyboardRequest)
        /// Ours and complete, but not allowed; delete at once.
        case refused(udid: String, KeyboardFailure)
        case notOurs
        /// Named like a request; may still be half-written.
        case unreadable
    }

    /// Only these keys may appear. A "passcode" key, or any other, refuses
    /// the whole request rather than being quietly ignored.
    public static let allowedKeys: Set<String> = ["udid", "requested_at", "requested_by", "action", "text"]

    /// "keyboard-<udid>.json" gives the UDID; any other name gives nil.
    public static func udid(fromFileName name: String) -> String? {
        guard name.hasPrefix("keyboard-"), name.hasSuffix(".json") else { return nil }
        let udid = String(name.dropFirst("keyboard-".count).dropLast(".json".count))
        return ExpectedReset.fileName(udid: udid) != nil ? udid : nil
    }

    /// Test text digit cap; every passcode is longer.
    public static let maxTestDigits = 3

    /// The test text rule: HIDKeyboard's validator, at least one letter, and
    /// at most three digits. This path must never carry a passcode. A numeric
    /// passcode field may skip letters and spaces, so "a 1234" would still be
    /// four digits typed into a lock screen: a wrong attempt.
    public static func isAllowedTestText(_ s: String) -> Bool {
        let bytes = s.utf8
        return HIDKeyboard.isValidTestText(s) && bytes.contains { (0x61...0x7A).contains($0) }
            && bytes.filter { (0x30...0x39).contains($0) }.count <= maxTestDigits
    }

    /// Parse one file. The body's udid must match the file name, so one
    /// phone's file can't drive another's keyboard.
    public static func read(fileName: String, data: Data?) -> Read {
        guard let nameUDID = udid(fromFileName: fileName) else { return .notOurs }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let udid = obj["udid"] as? String, udid == nameUDID,
              let raw = obj["requested_at"] as? String, let at = ExpectedReset.parseISO(raw)
        else { return .unreadable }
        guard Set(obj.keys).isSubset(of: allowedKeys) else { return .refused(udid: udid, .badRequest) }
        guard let name = obj["action"] as? String, let action = KeyboardAction(rawValue: name) else {
            return .refused(udid: udid, .unknownAction)
        }
        var text: String?
        switch action {
        case .test:
            guard let t = obj["text"] as? String, isAllowedTestText(t) else { return .refused(udid: udid, .badText) }
            text = t
        case .pair, .forget, .autoOn, .autoOff:
            guard obj["text"] == nil else { return .refused(udid: udid, .badText) }
        }
        let by = (obj["requested_by"] as? String) ?? "?"
        let clean = String(by.filter { $0.isASCII && !$0.isNewline }.prefix(64))
        return .request(KeyboardRequest(udid: udid, requestedAt: at, requestedBy: clean, action: action, text: text))
    }
}

public enum KeyboardRequestGate {
    /// Pairing window length. imirror-ctl waits 130 s.
    public static let pairWindowSec: TimeInterval = 120
    /// imirror-ctl gives up by then; nobody awaits older requests.
    public static let maxAgeSec: TimeInterval = 120

    /// Whether to act on `r` now; nil means go. Pairing needs the phone on
    /// USB, so a typo can't tie a central to a phone that isn't here. A test
    /// needs a pairing, and so does turning auto-unlock on. Forget and
    /// auto off always go, even for a phone long gone.
    public static func refusal(_ r: KeyboardRequest, attached: Bool, paired: Bool, wallNow: Date) -> KeyboardFailure? {
        if abs(wallNow.timeIntervalSince(r.requestedAt)) > maxAgeSec { return .stale }
        switch r.action {
        case .pair: return attached ? nil : .notAttached
        case .test: return paired ? nil : .notPaired
        case .autoOn: return !attached ? .notAttached : (paired ? nil : .notPaired)
        case .forget, .autoOff: return nil
        }
    }
}

/// The keyboard event's `detail`. README "Files other tools read" lists them.
public enum KeyboardEventDetail: String, Sendable, CaseIterable {
    case paired, ambiguous, timeout, connected, disconnected, failed, forgotten
    case typedTest = "typed_test"
    case typedPasscode = "typed_passcode"
    /// Auto-unlock was turned on or off (reason: who or why).
    case autoOn = "auto_on"
    case autoOff = "auto_off"
    /// Auto-unlock sent the wake (Shift) to a locked phone.
    case autoWake = "auto_wake"
    /// Auto-unlock typed the passcode; `chars` is its length.
    case autoTyped = "auto_typed"
    /// A reading after typing showed the phone unlocked.
    case autoUnlocked = "auto_unlocked"
    /// The attempt failed and turned auto-unlock off.
    case autoFailed = "auto_failed"
    /// The attempt stopped before any digit went out.
    case autoAborted = "auto_aborted"

    /// What a pairing window's outcome is logged as.
    public init(_ outcome: PairingOutcome) {
        switch outcome {
        case .paired: self = .paired
        case .ambiguous: self = .ambiguous
        case .none: self = .timeout
        }
    }
}

extension DeviceEvent {
    /// One keyboard event. `chars` is a count only; text never goes in.
    public static func keyboard(at date: Date, udid: String, alias: String, _ detail: KeyboardEventDetail,
                                reason: KeyboardFailure? = nil, chars: Int? = nil,
                                transport: KeyboardTransportKind? = nil) -> DeviceEvent {
        DeviceEvent(at: date, udid: udid, alias: alias, event: .keyboard, reason: reason?.rawValue,
                    detail: detail.rawValue, chars: chars, transport: transport?.rawValue)
    }

    /// The same, with a raw reason: auto-unlock reasons are not
    /// KeyboardFailures. The timings are milliseconds, numbers only.
    public static func keyboard(at date: Date, udid: String, alias: String, _ detail: KeyboardEventDetail,
                                reason: String?, chars: Int? = nil, probeAgeMs: Int? = nil, sendMs: Int? = nil,
                                transport: KeyboardTransportKind? = nil) -> DeviceEvent {
        var e = DeviceEvent(at: date, udid: udid, alias: alias, event: .keyboard, reason: reason,
                            detail: detail.rawValue, chars: chars, transport: transport?.rawValue)
        e.probeAgeMs = probeAgeMs
        e.sendMs = sendMs
        return e
    }
}
