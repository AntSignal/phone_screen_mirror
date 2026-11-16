import Foundation

// Which phones may be unlocked by iMirror typing their passcode, and the
// history that rate-limits it. Stored as JSON in UserDefaults under
// `imirror.autoUnlock`. Off is the default for every phone, and anything
// odd in the stored value reads as off: a wrong attempt counts toward the
// phone's lockout, so a doubt must never turn typing on.
// Nothing here holds the passcode itself.

/// Who last turned auto-unlock on or off.
public enum AutoUnlockChangeSource: String, Sendable {
    case settings, request, failure
}

/// Why something about auto-unlock happened. Logged as the keyboard
/// event's `reason`, so these names are part of the README contract.
public enum AutoUnlockReason: String, Sendable, CaseIterable {
    case settings, request
    case stillLocked = "still_locked"
    case unverified
    case interrupted
    case unlockedBeforeTyping = "unlocked_before_typing"
    case lockUnknown = "lock_unknown"
    case probeTimeout = "probe_timeout"
    /// Unlocked more than verifyProvenSec after typing.
    case unlockedLate = "unlocked_late"
    /// The first key may have left too late (firstKeyMaxSec).
    case slowKeyboard = "slow_keyboard"
    /// The phone's alias changed, so its passcode key did too.
    case renamed

    /// The reasons that may be stored as `disabled_reason`.
    public static let disabling: Set<AutoUnlockReason> = [.stillLocked, .unverified, .interrupted, .unlockedLate,
                                                          .slowKeyboard]
}

/// What devices.json shows as `auto_unlock`.
public enum AutoUnlockState: String, Sendable {
    case on, off
    case offAfterFailure = "off_after_failure"
}

/// One phone's stored state.
public struct AutoUnlockRecord: Equatable, Sendable {
    public var enabled = false
    public var changedAt: Date?
    public var changedBy: AutoUnlockChangeSource?
    /// Set when a failure turned it off; cleared when a person turns it on.
    public var disabledReason: AutoUnlockReason?
    /// Last hour's attempts, automatic or clicked, oldest first.
    public var attempts: [Date] = []
    /// True once this lock episode has had its one attempt.
    public var episodeAttempted = false
    /// Set before the wake, cleared when the attempt ends. Still set at
    /// launch means iMirror stopped mid-attempt.
    public var pendingSince: Date?

    public init() {}

    /// Most attempts kept; the hourly cap needs only three.
    public static let maxKeptAttempts = 10

    public var state: AutoUnlockState {
        if enabled { return .on }
        return disabledReason == nil ? .off : .offAfterFailure
    }

    /// A person turned it on. History and the episode flag stay, so
    /// turning it off and on never buys a second try.
    public mutating func enable(by: AutoUnlockChangeSource, at: Date) {
        enabled = true; changedBy = by; changedAt = at; disabledReason = nil
    }

    /// `reason` is set only when a failure turned it off.
    public mutating func disable(reason: AutoUnlockReason?, by: AutoUnlockChangeSource, at: Date) {
        enabled = false; changedBy = by; changedAt = at
        disabledReason = reason.flatMap { AutoUnlockReason.disabling.contains($0) ? $0 : nil }
    }

    /// Drop attempts older than an hour; keep future ones (fail closed).
    public mutating func prune(wallNow: Date) {
        attempts = Array(attempts.filter { wallNow.timeIntervalSince($0) < 3600 }.suffix(Self.maxKeptAttempts))
    }
}

public struct AutoUnlockSettings: Equatable, Sendable {
    public static let defaultsKey = "imirror.autoUnlock"
    /// Only these keys may appear in an entry; any other makes it off.
    public static let allowedKeys: Set<String> = ["enabled", "changed_at", "changed_by", "disabled_reason",
                                                  "attempts", "episode_attempted", "pending_since"]

    public private(set) var records: [String: AutoUnlockRecord] = [:]

    public init() {}

    /// Parse the stored value. An entry left with `pending_since` means
    /// iMirror stopped mid-attempt: it comes back off, reason
    /// `interrupted`, and its UDID is returned so the app can say so.
    public static func load(_ data: Data?, wallNow: Date) -> (AutoUnlockSettings, interrupted: [String]) {
        var s = AutoUnlockSettings()
        var interrupted: [String] = []
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (s, [])
        }
        for (udid, raw) in obj where ExpectedReset.fileName(udid: udid) != nil {
            var r = parse(raw) ?? garbled()
            r.prune(wallNow: wallNow)
            if r.pendingSince != nil {
                r.pendingSince = nil
                r.disable(reason: .interrupted, by: .failure, at: wallNow)
                interrupted.append(udid)
            }
            s.records[udid] = r
        }
        return (s, interrupted.sorted())
    }

    /// An entry we cannot read: off, and its episode counted as spent.
    private static func garbled() -> AutoUnlockRecord {
        var r = AutoUnlockRecord()
        r.episodeAttempted = true
        return r
    }

    private static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// One entry, or nil when anything about it is odd.
    private static func parse(_ raw: Any) -> AutoUnlockRecord? {
        guard let e = raw as? [String: Any], Set(e.keys).isSubset(of: allowedKeys),
              isBool(e["enabled"]), let enabled = e["enabled"] as? Bool else { return nil }
        var r = AutoUnlockRecord()
        r.enabled = enabled
        func date(_ key: String) -> Date?? {
            switch e[key] {
            case nil, is NSNull: return .some(nil)
            case let s as String: return ExpectedReset.parseISO(s).map { .some($0) }
            default: return nil
            }
        }
        guard let changedAt = date("changed_at"), let pending = date("pending_since") else { return nil }
        r.changedAt = changedAt
        r.pendingSince = pending
        switch e["changed_by"] {
        case nil, is NSNull: break
        case let s as String:
            guard let by = AutoUnlockChangeSource(rawValue: s) else { return nil }
            r.changedBy = by
        default: return nil
        }
        switch e["disabled_reason"] {
        case nil, is NSNull: break
        case let s as String:
            guard let why = AutoUnlockReason(rawValue: s), AutoUnlockReason.disabling.contains(why) else { return nil }
            r.disabledReason = why
        default: return nil
        }
        if let a = e["attempts"] {
            guard let list = a as? [Any] else { return nil }
            for item in list {
                guard let s = item as? String, let d = ExpectedReset.parseISO(s) else { return nil }
                r.attempts.append(d)
            }
            r.attempts.sort()
        }
        if let ep = e["episode_attempted"] {
            guard isBool(ep), let b = ep as? Bool else { return nil }
            r.episodeAttempted = b
        }
        // On yet failed is contradictory: read it as off.
        if r.enabled, r.disabledReason != nil { r.enabled = false }
        return r
    }

    /// A phone never seen is off.
    public func record(for udid: String) -> AutoUnlockRecord { records[udid] ?? AutoUnlockRecord() }

    public mutating func set(_ r: AutoUnlockRecord, for udid: String) {
        guard ExpectedReset.fileName(udid: udid) != nil else { return }
        records[udid] = r
    }

    public mutating func enable(udid: String, by: AutoUnlockChangeSource, at: Date) {
        var r = record(for: udid)
        r.enable(by: by, at: at)
        set(r, for: udid)
    }

    public mutating func disable(udid: String, reason: AutoUnlockReason?, by: AutoUnlockChangeSource, at: Date) {
        var r = record(for: udid)
        r.disable(reason: reason, by: by, at: at)
        set(r, for: udid)
    }

    /// A definite unlocked reading ends the episode.
    public mutating func noteUnlocked(udid: String) {
        guard records[udid]?.episodeAttempted == true else { return }
        records[udid]?.episodeAttempted = false
    }

    /// Sorted-key JSON, so the same settings give the same bytes.
    public func encode() -> Data {
        var obj: [String: Any] = [:]
        for (udid, r) in records {
            obj[udid] = [
                "enabled": r.enabled,
                "changed_at": r.changedAt.map(DeviceEventCodec.timestamp) ?? NSNull(),
                "changed_by": r.changedBy?.rawValue ?? NSNull(),
                "disabled_reason": r.disabledReason?.rawValue ?? NSNull(),
                "attempts": r.attempts.map(DeviceEventCodec.timestamp),
                "episode_attempted": r.episodeAttempted,
                "pending_since": r.pendingSince.map(DeviceEventCodec.timestamp) ?? NSNull(),
            ] as [String: Any]
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
