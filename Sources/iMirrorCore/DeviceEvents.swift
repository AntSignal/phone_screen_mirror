import Foundation

// What the app tells other tools about each phone, besides devices.json:
// - `DeviceReason`: why a phone is not ready (devices.json "reason");
// - `DeviceEvent`: one line of ~/Library/Application Support/iMirror/events.jsonl;
// - expected resets: a note a client leaves before `devicectl install`.
// The README's "Files other tools read" section is the contract; keep the
// two in step. Nothing here may carry a secret: lines are read by anyone.

/// Why a phone is not ready. Readers must accept values they do not know.
public enum DeviceReason: String, CaseIterable, Sendable {
    /// The phone dropped off USB and its chain is being rebuilt.
    case usbReset = "usb_reset"
    /// WDA was up, then stopped answering.
    case wdaWedged = "wda_wedged"
    /// The XCTest "Enable UI Automation" passcode sheet is waiting.
    case needsPasscode = "needs_passcode"
    case locked
    /// The shared go-ios tunnel has no route to this phone.
    case tunnelDown = "tunnel_down"
    case macAsleep = "mac_asleep"
    /// The ladder stopped trying for a while; see next_retry_at.
    case gaveUp = "gave_up"
    /// A restart is under way.
    case recovering
    /// First bring-up: WDA has not answered yet.
    case booting
    /// The phone does not trust this Mac ("Trust This Computer"), or the
    /// runner's developer (Settings > General > VPN & Device Management).
    case untrusted
}

/// What `deviceReason` looks at. The app fills it from its controller.
public struct DeviceReasonInputs: Equatable, Sendable {
    public var ready: Bool
    /// What runwda's output says needs a person (RunwdaLog.swift).
    public var runwda: RunwdaLogClass?
    public var gaveUp: Bool
    public var macAsleep: Bool
    /// A USB reset restarted the chain and WDA has not answered since.
    public var usbReset: Bool
    public var tunnelHasDevice: Bool
    /// The ladder has restarted something for this outage.
    public var restarting: Bool
    public var everConnected: Bool

    public init(ready: Bool, runwda: RunwdaLogClass? = nil, gaveUp: Bool = false, macAsleep: Bool = false, usbReset: Bool = false,
                tunnelHasDevice: Bool = true, restarting: Bool = false, everConnected: Bool = false) {
        self.ready = ready; self.runwda = runwda; self.gaveUp = gaveUp; self.macAsleep = macAsleep
        self.usbReset = usbReset; self.tunnelHasDevice = tunnelHasDevice
        self.restarting = restarting; self.everConnected = everConnected
    }
}

/// The one reason to publish, or nil when the phone is ready. The cause a
/// client can act on, or wait out, comes before the generic ones.
public func deviceReason(_ i: DeviceReasonInputs) -> DeviceReason? {
    if i.ready { return nil }
    if let r = i.runwda { return r.reason }   // a person can fix it now
    if i.gaveUp { return .gaveUp }
    if i.macAsleep { return .macAsleep }
    if i.usbReset { return .usbReset }
    if !i.tunnelHasDevice { return .tunnelDown }
    if i.restarting { return .recovering }
    return i.everConnected ? .wdaWedged : .booting
}

/// Remembers the last published state and reason, and since when.
public struct PublishedState: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var from: RegisteredDevice.State?
        public var fromReason: DeviceReason?
        public var to: RegisteredDevice.State
        public var toReason: DeviceReason?
    }

    public private(set) var state: RegisteredDevice.State?
    public private(set) var reason: DeviceReason?
    public private(set) var since: Date?

    public init() {}

    /// Record what is published now. Returns the change, or nil if neither
    /// the state nor the reason moved (then `since` stays put).
    public mutating func update(state new: RegisteredDevice.State, reason newReason: DeviceReason?,
                                now: Date) -> Change? {
        guard new != state || newReason != reason || since == nil else { return nil }
        let change = Change(from: state, fromReason: reason, to: new, toReason: newReason)
        state = new
        reason = newReason
        since = now
        return change
    }
}

// MARK: - events.jsonl

public enum DeviceEventKind: String, Sendable {
    case state, restart, request, wake, sleep, passcode
    case giveUp = "give_up"
    case autoRetry = "auto_retry"
    case usbReset = "usb_reset"
    case usbResetIgnored = "usb_reset_ignored"
    /// The phone's runner is older than the bundled one and is reinstalled.
    case runnerUpgrade = "runner_upgrade"
}

/// One line of events.jsonl.
public struct DeviceEvent: Encodable, Equatable, Sendable {
    public static let maxDetail = 300

    public var ts: String
    public var udid: String
    public var alias: String
    public var event: String
    public var from: String?
    public var to: String?
    public var reason: String?
    public var detail: String?
    public var expected: Bool?

    public init(at date: Date, udid: String, alias: String, event: DeviceEventKind,
                from: String? = nil, to: String? = nil, reason: String? = nil,
                detail: String? = nil, expected: Bool? = nil) {
        ts = DeviceEventCodec.timestamp(date)
        self.udid = udid; self.alias = alias; self.event = event.rawValue
        self.from = from; self.to = to; self.reason = reason
        self.detail = detail.map(DeviceEventCodec.clip)
        self.expected = expected
    }
}

public enum DeviceEventCodec {
    /// Past this size the file moves to events.jsonl.1 (one old file kept).
    public static let rotateAtBytes: UInt64 = 5 * 1024 * 1024

    /// One compact line, newline included. Sorted keys keep it diffable.
    public static func line(_ e: DeviceEvent) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(e)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// True when appending `adding` bytes would take the file past the limit.
    public static func shouldRotate(currentSize: UInt64, adding: Int,
                                    limit: UInt64 = rotateAtBytes) -> Bool {
        currentSize > 0 && currentSize + UInt64(max(adding, 0)) > limit
    }

    /// UTC ISO-8601 with milliseconds: events can land in the same second.
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// One line, bounded. Keeps a long go-ios message from bloating the log.
    static func clip(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return flat.count <= DeviceEvent.maxDetail ? flat : String(flat.prefix(DeviceEvent.maxDetail)) + "…"
    }
}

// MARK: - Expected resets

/// A client about to run `devicectl device install|launch` writes
/// expected-resets/<udid>.json = {"until": ISO, "by": "..."}. The USB reset
/// that follows is then logged as expected. Recovery is never skipped for it.
public enum ExpectedReset {
    /// A note promising more than this far ahead is ignored as bogus.
    public static let maxAheadSec: TimeInterval = 600

    /// True when the note's "until" is still in the future (and sane).
    public static func holds(_ data: Data?, now: Date) -> Bool {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["until"] as? String, let until = parseISO(raw) else { return false }
        return until > now && until.timeIntervalSince(now) <= maxAheadSec
    }

    /// The file name for a phone, or nil if the UDID could escape the folder.
    public static func fileName(udid: String) -> String? {
        let ok = !udid.isEmpty && udid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return ok ? "\(udid).json" : nil
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
