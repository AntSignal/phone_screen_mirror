import Foundation

// Keyboard requests: a client (scripts/imirror-ctl) writes
// requests/keyboard-<udid>.json, and the app pairs, tests or forgets the
// Bluetooth keyboard for that phone. The README's "Files other tools read"
// is the contract. A file can be written by anyone who can write the folder,
// so nothing here can type a passcode: only a click in Settings does that.

public enum KeyboardAction: String, Sendable, CaseIterable {
    /// Open a pairing window for this phone.
    case pair
    /// Drop this phone's central from keyboard-pairs.json.
    case forget
    /// Type harmless test text into this phone.
    case test
}

public struct KeyboardRequest: Equatable, Sendable {
    public var udid: String
    public var requestedAt: Date
    /// Who asked, for the log only. Clipped like a restart request's.
    public var requestedBy: String
    public var action: KeyboardAction
    /// Set for `test` only, and always passes `KeyboardRequestFile.isAllowedTestText`.
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
}

public enum KeyboardRequestFile {
    public enum Read: Equatable, Sendable {
        case request(KeyboardRequest)
        /// Ours and complete, but not allowed. Its file can go at once.
        case refused(udid: String, KeyboardFailure)
        case notOurs
        /// Named like a request but not one; may still be half-written.
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

    /// The test text rule: HIDKeyboard's validator plus at least one letter.
    /// Digits alone could be a passcode, and this path must never carry one.
    public static func isAllowedTestText(_ s: String) -> Bool {
        HIDKeyboard.isValidTestText(s) && s.contains { ("a"..."z").contains($0) }
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
        case .pair, .forget:
            guard obj["text"] == nil else { return .refused(udid: udid, .badText) }
        }
        let by = (obj["requested_by"] as? String) ?? "?"
        let clean = String(by.filter { $0.isASCII && !$0.isNewline }.prefix(64))
        return .request(KeyboardRequest(udid: udid, requestedAt: at, requestedBy: clean, action: action, text: text))
    }
}

public enum KeyboardRequestGate {
    /// How long a pairing window stays open. imirror-ctl waits 130 s.
    public static let pairWindowSec: TimeInterval = 120
    /// imirror-ctl gives up by then, so an older request has no one waiting.
    public static let maxAgeSec: TimeInterval = 120

    /// Whether to act on `r` now; nil means go. Pairing needs the phone on
    /// USB, so a typo can't tie a central to a phone that isn't here. A test
    /// needs a pairing. Forget always goes, even for a phone long gone.
    public static func refusal(_ r: KeyboardRequest, attached: Bool, paired: Bool, wallNow: Date) -> KeyboardFailure? {
        if abs(wallNow.timeIntervalSince(r.requestedAt)) > maxAgeSec { return .stale }
        switch r.action {
        case .pair: return attached ? nil : .notAttached
        case .test: return paired ? nil : .notPaired
        case .forget: return nil
        }
    }
}

/// The keyboard event's `detail`. README "Files other tools read" lists them.
public enum KeyboardEventDetail: String, Sendable, CaseIterable {
    case paired, ambiguous, timeout, connected, disconnected, failed, forgotten
    case typedTest = "typed_test"
    case typedPasscode = "typed_passcode"

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
                                reason: KeyboardFailure? = nil, chars: Int? = nil) -> DeviceEvent {
        DeviceEvent(at: date, udid: udid, alias: alias, event: .keyboard, reason: reason?.rawValue,
                    detail: detail.rawValue, chars: chars)
    }
}
