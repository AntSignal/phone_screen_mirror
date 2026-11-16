import Foundation

// Is the phone locked? go-ios's `lockdown get PasswordProtected` answers
// over usbmux, so it still works while the shared tunnel is down because
// the phone is locked. "true" means locked; "false" means unlocked, even
// on a phone that has a passcode. Anything else means we cannot tell, and
// "cannot tell" never lets iMirror type (PasscodeGate.swift).

/// One lock probe's answer.
public enum LockReading: String, Equatable, Sendable {
    case locked, unlocked, unknown
}

/// Every timing rule for the lock probe and auto-unlock, in one place so
/// tests can name them.
public enum AutoUnlockTiming {
    /// A reading older than this cannot approve typing.
    public static let freshProbeSec: TimeInterval = 2
    /// A locked reading holds the ladder for this long.
    public static let lockFreshSec: TimeInterval = 15
    /// A lock must be this old before a wake, so a person unlocking wins.
    public static let settleSec: TimeInterval = 20
    /// Least time between two automatic attempts (wall clock).
    public static let minGapSec: TimeInterval = 120
    /// Most automatic attempts in any rolling hour.
    public static let maxPerHour = 3
    /// How long after typing a reading may still prove the unlock.
    public static let verifySec: TimeInterval = 15
    /// After the wake, a fresh reading must come within this.
    public static let postWakeProbeDeadlineSec: TimeInterval = 5
    /// Probe interval while WDA is down.
    public static let probeIntervalSec: TimeInterval = 5
    /// Probe interval while checking an attempt.
    public static let verifyProbeIntervalSec: TimeInterval = 1
    /// A probe that runs longer is killed and reads unknown.
    public static let probeTimeoutSec: TimeInterval = 3
    /// After an unlock, how long go-ios gets to retry the tunnel itself.
    public static let unlockTunnelWaitSec: TimeInterval = 20
    /// After an unlock, retry a refused tunnel restart this often.
    public static let unlockTunnelRetrySec: TimeInterval = 15
    /// At most this many such retries per unlock.
    public static let unlockTunnelRetries = 10
    /// An unlock seen later than this after typing proves nothing.
    public static let verifyProvenSec: TimeInterval = 5
    /// Most seconds from the approving reading to the first key.
    public static let firstKeyMaxSec: TimeInterval = 4.5
    /// A wake or passcode SEND running longer ends the try.
    public static let sendDeadlineSec: TimeInterval = 75
    /// Longest a locked phone may keep the Mac awake.
    public static let keepAwakeLockedSec: TimeInterval = 600
}

/// How old the approving lock reading was when the first key left.
public enum FirstKeyAge {
    /// `firstKeyAt` is the moment the transport sent its first key, when
    /// it can see that (this Mac's Bluetooth). The dongle cannot: it
    /// connects, waits and types inside one SEND. Its first key is no
    /// later than the SEND's end minus the steps' own delays, so that
    /// gives an upper bound, which is the safe side.
    public static func seconds(readingStartedAt: TimeInterval, firstKeyAt: TimeInterval?,
                               sendStartedAt: TimeInterval, sendEndedAt: TimeInterval,
                               stepDelaysMs: Int) -> TimeInterval {
        if let at = firstKeyAt { return at - readingStartedAt }
        let bound = max(sendStartedAt, sendEndedAt - TimeInterval(max(stepDelaysMs, 0)) / 1000)
        return bound - readingStartedAt
    }
}

public enum LockProbeParsing {
    /// The go-ios argv for one phone, or nil when the UDID is unsafe.
    public static func args(udid: String) -> [String]? {
        guard ExpectedReset.fileName(udid: udid) != nil else { return nil }
        return ["lockdown", "get", "PasswordProtected", "--udid=\(udid)"]
    }

    /// Strict: exactly "true" or "false" after trimming. go-ios prints
    /// "null" with exit 0 when lockdown refused, and an empty stdout with
    /// exit 1 when the phone is not on usbmux; both are unknown.
    public static func reading(status: Int32, stdout: Data, timedOut: Bool) -> LockReading {
        guard !timedOut, status == 0 else { return .unknown }
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "true": return .locked
        case "false": return .unlocked
        default: return .unknown
        }
    }
}

/// A reading and when its probe started (monotonic seconds).
public struct LockSample: Equatable, Sendable {
    public var reading: LockReading
    public var startedAt: TimeInterval

    public init(_ reading: LockReading, startedAt: TimeInterval) {
        self.reading = reading; self.startedAt = startedAt
    }
}

/// A definite change in what the probe says.
public enum LockTransition: Equatable, Sendable {
    case becameLocked, becameUnlocked
}

/// Remembers one phone's lock readings. An episode starts at the first
/// locked reading and ends only at a definite unlocked one, so an unknown
/// reading or a gap never starts a new episode (and a new attempt).
public struct LockWatch: Equatable, Sendable {
    /// The newest reading, unknown ones included.
    public private(set) var latest: LockSample?
    /// The newest locked or unlocked reading.
    public private(set) var lastDefinite: LockSample?
    /// When this lock episode's first locked reading started.
    public private(set) var episodeStart: TimeInterval?

    public init() {}

    /// Record a reading. An older reading than the latest is dropped. A
    /// first locked reading is a transition; a first unlocked one is not,
    /// since nothing changed that anyone needs to hear about.
    @discardableResult
    public mutating func record(_ r: LockReading, startedAt: TimeInterval) -> LockTransition? {
        if let l = latest, startedAt < l.startedAt { return nil }
        let sample = LockSample(r, startedAt: startedAt)
        latest = sample
        guard r != .unknown else { return nil }
        let before = lastDefinite?.reading
        lastDefinite = sample
        if r == .locked {
            if episodeStart == nil { episodeStart = startedAt }
            return before == .locked ? nil : .becameLocked
        }
        episodeStart = nil
        return before == .locked ? .becameUnlocked : nil
    }

    /// True when the last definite reading said locked and is recent.
    public func isLocked(now: TimeInterval) -> Bool {
        guard let d = lastDefinite, d.reading == .locked else { return false }
        return now - d.startedAt <= AutoUnlockTiming.lockFreshSec
    }
}
