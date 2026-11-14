import Foundation

// What `ios runwda`'s own output says, so a phone waiting on a person is not
// treated as a wedge and restarted over and over. The app keeps each child's
// recent output in an OutputRing (it used to go to /dev/null) and runs every
// new runwda line through classifyRunwdaLine.

/// A cause in runwda's output that only a person at the phone can fix.
public enum RunwdaLogClass: Equatable, Sendable {
    /// The XCTest "Enable UI Automation" passcode sheet is up. testmanagerd
    /// does not answer go-ios until it is answered, so go-ios times out.
    case needsPasscode
    /// The phone is locked (before first unlock, or lockdown refused).
    case locked
    /// The phone does not trust this Mac, or the runner's developer.
    case untrusted

    public var reason: DeviceReason {
        switch self {
        case .needsPasscode: return .needsPasscode
        case .locked: return .locked
        case .untrusted: return .untrusted
        }
    }
}

/// One line of runwda output (go-ios writes JSON lines; plain text is fine
/// too). Matching is on lower-cased substrings, as go-ios words them.
public func classifyRunwdaLine<S: StringProtocol>(_ line: S) -> RunwdaLogClass? {
    let l = line.lowercased()
    if l.contains("cannot initiate a ide session"), l.contains("timed out") { return .needsPasscode }
    let locked = ["passwordprotected", "devicelocked", "device is locked", "device locked"]
    if locked.contains(where: l.contains) { return .locked }
    let untrusted = ["pairingdialogresponsepending", "userdeniedpairing", "invalidhostid",
                     "please accept the pairingdialog", "not been explicitly trusted",
                     "could not find pair record"]
    if untrusted.contains(where: l.contains) { return .untrusted }
    return nil
}

/// The last classified line in `text` wins: it is the newest news.
public func classifyRunwdaLog(_ text: String) -> RunwdaLogClass? {
    var last: RunwdaLogClass?
    for line in text.split(whereSeparator: \.isNewline) {
        if let c = classifyRunwdaLine(line) { last = c }
    }
    return last
}

/// A short form of go-ios's own error line ("msg: err"), for devices.json
/// last_error, or nil. Only go-ios's JSON error lines qualify: runwda also
/// relays the runner's output, which can echo text an agent typed.
public func runwdaErrorSummary<S: StringProtocol>(_ line: S, maxLength: Int = 200) -> String? {
    let raw = String(line).trimmingCharacters(in: .whitespaces)
    guard raw.hasPrefix("{"),
          let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
    let level = (obj["level"] as? String ?? "").lowercased()
    guard level == "error" || level == "fatal" else { return nil }
    let text = [obj["msg"], obj["err"] ?? obj["error"]].compactMap { $0 as? String }.joined(separator: ": ")
    guard !text.isEmpty else { return nil }
    return text.count <= maxLength ? text : String(text.prefix(maxLength)) + "…"
}

/// A child's most recent output, bounded, split into whole lines.
public struct OutputRing: Equatable, Sendable {
    public let capacity: Int
    public private(set) var tail = Data()
    private var partial = Data()

    public init(capacity: Int = 16 * 1024) { self.capacity = capacity }

    public var text: String { String(decoding: tail, as: UTF8.self) }

    /// Keep `chunk` and return the lines it completed. A line longer than
    /// the capacity is cut, so one runaway line cannot grow memory.
    public mutating func append(_ chunk: Data) -> [String] {
        tail.append(chunk)
        if tail.count > capacity { tail = tail.suffix(capacity) }
        partial.append(chunk)
        var lines: [String] = []
        while let nl = partial.firstIndex(of: 0x0A) {
            lines.append(String(decoding: partial[partial.startIndex..<nl], as: UTF8.self))
            partial = Data(partial[partial.index(after: nl)...])
        }
        if partial.count > capacity { partial = Data(partial.suffix(capacity)) }
        return lines
    }
}

/// How long runwda is left alone while the XCTest passcode sheet waits.
///
/// Killing or restarting the runner then only raises the sheet again, so
/// while `holding` the readiness kill and the ladder's restarts pause and
/// runwda retries at a steady pace. After `capSec` normal recovery resumes:
/// nobody may be coming. Monotonic seconds.
public struct PasscodeHold: Equatable, Sendable {
    public static let capSec: TimeInterval = 600

    /// When the sheet was first seen; nil when not waiting on it.
    public private(set) var since: TimeInterval?

    public init() {}

    /// runwda said the sheet is up. A hold that ran out stays out until
    /// `clear()`, or a sheet nobody answers would hold recovery forever.
    public mutating func sheetSeen(now: TimeInterval) {
        if since == nil { since = now }
    }

    /// WDA answered, or a person asked for a retry.
    public mutating func clear() { since = nil }

    public func holding(now: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since < Self.capSec
    }
}

/// The wait before respawning a child that exited. Doubles per quick
/// failure up to 60 s; a held runwda retries at a steady 15 s instead, so
/// it picks up an answered sheet soon and never trips the give-up breaker.
public func managedProcessRespawnDelay(base: TimeInterval, failures: Int, held: Bool) -> TimeInterval {
    if held { return max(base, 15) }
    return min(base * pow(2.0, Double(max(0, failures - 1))), 60)
}
