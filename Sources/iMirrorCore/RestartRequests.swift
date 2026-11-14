import Foundation

// Restart requests: a client (the MCP server's ios_recover, scripts/imirror-ctl)
// writes requests/restart-<udid>.json next to devices.json, and the app
// restarts that phone's chain. Agents have nobody to tap "retry", so this is
// their retry button. The README's "Files other tools read" is the contract.

/// One request, as read from its file.
public struct RestartRequest: Equatable, Sendable {
    public var udid: String
    public var requestedAt: Date
    /// Who asked, for the log only. Clipped: anyone can write the file.
    public var requestedBy: String

    public init(udid: String, requestedAt: Date, requestedBy: String) {
        self.udid = udid; self.requestedAt = requestedAt; self.requestedBy = requestedBy
    }
}

public enum RestartRequestFile {
    public enum Read: Equatable, Sendable {
        case request(RestartRequest)
        /// Not a request file (a client's temp file, say). Leave it alone.
        case notOurs
        /// Named like a request but not one; may still be half-written.
        case unreadable
    }

    /// A file this new may be mid-write; only older bad files are deleted.
    public static let unreadableGraceSec: TimeInterval = 10

    /// "restart-<udid>.json" gives the UDID; any other name gives nil.
    public static func udid(fromFileName name: String) -> String? {
        guard name.hasPrefix("restart-"), name.hasSuffix(".json") else { return nil }
        let udid = String(name.dropFirst("restart-".count).dropLast(".json".count))
        return ExpectedReset.fileName(udid: udid) != nil ? udid : nil
    }

    /// Parse one file. The body's udid must match the file name, so one
    /// phone's file can't restart another.
    public static func read(fileName: String, data: Data?) -> Read {
        guard let nameUDID = udid(fromFileName: fileName) else { return .notOurs }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let udid = obj["udid"] as? String, udid == nameUDID,
              let raw = obj["requested_at"] as? String, let at = ExpectedReset.parseISO(raw)
        else { return .unreadable }
        let by = (obj["requested_by"] as? String) ?? "?"
        let clean = String(by.filter { $0.isASCII && !$0.isNewline }.prefix(64))
        return .request(RestartRequest(udid: udid, requestedAt: at, requestedBy: clean))
    }
}

/// What the app did with a request. Logged as event "request", detail = rawValue.
public enum RestartRequestOutcome: String, Sendable {
    /// The phone's chain restarts now.
    case accepted
    /// A request for this phone was honoured in the last minute.
    case cooldown
    /// Written long ago (the app was off then), or dated in the future.
    case stale
    /// No phone with this UDID has a chain here.
    case notAttached = "not_attached"
}

/// The per-phone cooldown. Each session's MCP server may ask at once when a
/// phone stalls; without this they would knock its fresh chain down again
/// and again. Only honoured requests start the clock.
public struct RestartRequestGate: Equatable, Sendable {
    public static let cooldownSec: TimeInterval = 60
    /// imirror-ctl waits 30 s, so an older request has no one waiting on it.
    public static let maxAgeSec: TimeInterval = 120

    /// Uptime of the last honoured request, by UDID.
    public private(set) var lastHonoured: [String: TimeInterval] = [:]

    public init() {}

    /// `wallNow` judges the request's own timestamp; `uptime` the cooldown,
    /// so a clock change can't open it early.
    public mutating func decide(_ r: RestartRequest, attached: Bool,
                                wallNow: Date, uptime: TimeInterval) -> RestartRequestOutcome {
        guard attached else { return .notAttached }
        if abs(wallNow.timeIntervalSince(r.requestedAt)) > Self.maxAgeSec { return .stale }
        if let last = lastHonoured[r.udid], uptime - last < Self.cooldownSec { return .cooldown }
        lastHonoured[r.udid] = uptime
        return .accepted
    }
}
