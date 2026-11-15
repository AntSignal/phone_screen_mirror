import Foundation

// KeyboardPairs — which phone is which Bluetooth central. iMirror's keyboard
// must type into one phone only, and CoreBluetooth names a phone by a central
// UUID, not by its UDID. This map ties them together, and the pairing rule
// decides when a new link may be trusted. The file is
// ~/Library/Application Support/iMirror/keyboard-pairs.json:
//   {"<udid>": {"central": "<UUID>", "paired_at": "<ISO-8601>"}}

public struct KeyboardPair: Equatable, Sendable {
    /// CoreBluetooth's central identifier, upper-case UUID string.
    public var central: String
    public var pairedAt: Date

    public init(central: String, pairedAt: Date) { self.central = central; self.pairedAt = pairedAt }
}

public struct KeyboardPairs: Equatable, Sendable {
    public private(set) var byUDID: [String: KeyboardPair] = [:]

    public init() {}

    /// Reads the file. Bad entries are dropped one by one; a missing or
    /// broken file is an empty map, so the worst case is pairing again.
    public static func decode(_ data: Data?) -> KeyboardPairs {
        var out = KeyboardPairs()
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return out }
        for (udid, raw) in obj {
            guard let entry = raw as? [String: Any],
                  let central = entry["central"] as? String,
                  let rawAt = entry["paired_at"] as? String,
                  let at = ExpectedReset.parseISO(rawAt) else { continue }
            out.record(udid: udid, central: central, at: at)
        }
        return out
    }

    /// Sorted keys, so a rewrite with no change gives the same bytes.
    public func encode() -> Data {
        var obj: [String: [String: String]] = [:]
        for (udid, p) in byUDID {
            obj[udid] = ["central": p.central, "paired_at": DeviceEventCodec.timestamp(p.pairedAt)]
        }
        let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
        return data ?? Data("{}".utf8)
    }

    public func central(for udid: String) -> String? { byUDID[udid]?.central }

    public func udid(forCentral central: String) -> String? {
        guard let c = Self.normalized(central) else { return nil }
        return byUDID.first { $0.value.central == c }?.key
    }

    /// Ties `central` to `udid`. A central belongs to one phone only, so any
    /// older tie for it is dropped; otherwise two phones would share a keyboard.
    /// Returns false (and changes nothing) for a bad UDID or UUID.
    @discardableResult
    public mutating func record(udid: String, central: String, at: Date) -> Bool {
        guard ExpectedReset.fileName(udid: udid) != nil, let c = Self.normalized(central) else { return false }
        for (other, p) in byUDID where p.central == c { byUDID[other] = nil }
        byUDID[udid] = KeyboardPair(central: c, pairedAt: at)
        return true
    }

    public mutating func forget(udid: String) { byUDID[udid] = nil }

    /// Upper-case canonical UUID, or nil when it is not one.
    public static func normalized(_ central: String) -> String? {
        UUID(uuidString: central)?.uuidString
    }
}

/// What a pairing window ended with.
public enum PairingOutcome: Equatable, Sendable {
    case paired(central: String)
    /// Two or more new centrals: no way to tell which.
    case ambiguous(count: Int)
    case none
}

/// One phone's open pairing window.
public struct PairingWindow: Equatable, Sendable {
    public var udid: String
    public var opensAt: Date
    public var closesAt: Date
    /// Centrals subscribed before it opened; never the new phone.
    public var subscribedBefore: Set<String>

    public init(udid: String, opensAt: Date, closesAt: Date, subscribedBefore: Set<String>) {
        self.udid = udid; self.opensAt = opensAt; self.closesAt = closesAt
        self.subscribedBefore = Set(subscribedBefore.compactMap(KeyboardPairs.normalized))
    }
}

public enum PairingRule {
    /// A pairing is trusted only when exactly one new central subscribed
    /// while the window was open. New means: not subscribed before it opened,
    /// and not tied to another phone. Two candidates are refused, because a
    /// passcode sent to the wrong phone is a wrong passcode attempt.
    public static func decide(window: PairingWindow, subscriptions: [(central: String, at: Date)],
                              pairs: KeyboardPairs) -> PairingOutcome {
        var candidates = Set<String>()
        for s in subscriptions where s.at >= window.opensAt && s.at < window.closesAt {
            guard let c = KeyboardPairs.normalized(s.central), !window.subscribedBefore.contains(c) else { continue }
            if let owner = pairs.udid(forCentral: c), owner != window.udid { continue }
            candidates.insert(c)
        }
        switch candidates.count {
        case 0: return .none
        case 1: return .paired(central: candidates.first!)
        default: return .ambiguous(count: candidates.count)
        }
    }
}
