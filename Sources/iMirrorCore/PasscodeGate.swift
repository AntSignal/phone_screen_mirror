import Foundation

// PasscodeGate — decides when iMirror may type a phone's passcode by
// itself. A wrong attempt counts toward iOS's lockout, and keys sent to an
// unlocked phone land in whatever field has focus, so every doubt says no:
// typing needs a fresh "locked" reading taken after the wake, at most one
// try per lock episode, a gap between tries and an hourly cap. A failed
// try turns auto-unlock off until a person turns it on again.
// The app (AutoUnlock.swift) only carries out the steps decided here.

/// What the app knows about the phone and keyboard at this moment.
public struct PasscodeGateContext: Equatable, Sendable {
    /// The stored setting, as the app read it.
    public var enabled: Bool
    /// keyboard-pairs.json ties a keyboard to this UDID.
    public var paired: Bool
    public var attached: Bool
    public var macAsleep: Bool
    /// runwda says the "Enable UI Automation" sheet is up (out of scope).
    public var sheetUp: Bool
    /// WDA answers: nothing to get back, so nothing to type.
    public var wdaUp: Bool
    /// The keyboard runs a job that is not this gate's own sequence.
    public var keyboardBusy: Bool
    /// A clicked passcode is still being checked (same file).
    public var clickChecking: Bool
    /// Start of the probe now running; nil when none.
    public var probeInFlightSince: TimeInterval?

    public init(enabled: Bool, paired: Bool, attached: Bool, macAsleep: Bool = false, sheetUp: Bool = false,
                wdaUp: Bool = false, keyboardBusy: Bool = false, clickChecking: Bool = false,
                probeInFlightSince: TimeInterval? = nil) {
        self.enabled = enabled; self.paired = paired; self.attached = attached; self.macAsleep = macAsleep
        self.sheetUp = sheetUp; self.wdaUp = wdaUp; self.keyboardBusy = keyboardBusy
        self.clickChecking = clickChecking; self.probeInFlightSince = probeInFlightSince
    }
}

/// Why nothing happens now. Shown as status text, never logged per tick.
public enum PasscodeGateHold: String, Sendable, CaseIterable {
    case disabled
    case notPaired = "not_paired"
    case notAttached = "not_attached"
    case macAsleep = "mac_asleep"
    case sheet
    case wdaUp = "wda_up"
    case keyboardBusy = "keyboard_busy"
    case clickChecking = "click_checking"
    /// A wake SEND never came back; the try ended unsent.
    case sendStuck = "send_stuck"
    case lockUnknown = "lock_unknown"
    case probeTimeout = "probe_timeout"
    case unlocked
    case settling
    case triedThisEpisode = "tried_this_episode"
    case tooSoon = "too_soon"
    case hourlyCap = "hourly_cap"
    case inProgress = "in_progress"
}

/// Leave to type, for one phone, from one fresh locked reading. Only the
/// gate can make one (the init is internal), and it goes stale fast.
public struct AutoTypeApproval: Equatable, Sendable {
    public let udid: String
    public let readingStartedAt: TimeInterval

    init(udid: String, readingStartedAt: TimeInterval) {
        self.udid = udid; self.readingStartedAt = readingStartedAt
    }

    public func isFresh(now: TimeInterval) -> Bool {
        now - readingStartedAt <= AutoUnlockTiming.freshProbeSec
    }
}

/// How one automatic attempt ended.
public enum AutoUnlockOutcome: Equatable, Sendable {
    case unlocked
    /// Face ID or a person unlocked it during the wake: no digits sent.
    case unlockedBeforeTyping
    case stillLocked, unverified, interrupted
    /// Unlocked too long after typing to prove the code worked.
    case unlockedLate
    /// The first key may have left too late (slow reconnect).
    case lateFirstKey
    /// Stopped before typing; the hold says why.
    case aborted(PasscodeGateHold)
    /// The keyboard failed before any key went out.
    case notSent(KeyboardFailure)

    /// True for the outcomes that turn auto-unlock off.
    public var disables: Bool {
        switch self {
        case .stillLocked, .unverified, .interrupted, .unlockedLate, .lateFirstKey: return true
        default: return false
        }
    }

    /// The disabling reason, for the stored record and the event.
    public var reason: AutoUnlockReason? {
        switch self {
        case .stillLocked: return .stillLocked
        case .unverified: return .unverified
        case .interrupted: return .interrupted
        case .unlockedLate: return .unlockedLate
        case .lateFirstKey: return .slowKeyboard
        case .unlockedBeforeTyping: return .unlockedBeforeTyping
        case .aborted(.lockUnknown): return .lockUnknown
        case .aborted(.probeTimeout): return .probeTimeout
        default: return nil
        }
    }

    /// The keyboard event's `reason` for this outcome, if any.
    public var eventReason: String? {
        switch self {
        case .unlocked: return nil
        case .aborted(let h): return reason?.rawValue ?? h.rawValue
        case .notSent(let f): return f.rawValue
        default: return reason?.rawValue
        }
    }
}

/// What the app should do next.
public enum PasscodeGateStep: Equatable, Sendable {
    case nothing(PasscodeGateHold)
    /// Take a lock reading now.
    case probe
    /// Send the wake (Shift) only. Call wakeStarted first.
    case wake
    /// Type the passcode now, in this same main-thread turn.
    case type(AutoTypeApproval)
    /// Take a reading to check the attempt.
    case verifyProbe
    case finished(AutoUnlockOutcome)
}

/// How the typing SEND went.
public enum TypeResult: Equatable, Sendable {
    case sent
    /// An error after keys may have gone out: treated as sent.
    case maybeSent(KeyboardFailure)
    /// An error known to come before any key went out.
    case notSent(KeyboardFailure)

    /// Failures that happen before any key leaves the Mac.
    /// `.stale` comes only from the pre-first-key check.
    public static let beforeAnyKey: Set<KeyboardFailure> = [.notPaired, .dongleUnavailable, .noFile, .noPasscode,
                                                            .untypeable, .busy, .stale]

    public init(failure: KeyboardFailure?) {
        guard let f = failure else { self = .sent; return }
        self = Self.beforeAnyKey.contains(f) ? .notSent(f) : .maybeSent(f)
    }
}

/// One phone's gate. Phases: idle → waking → awaitingProbe → typing →
/// verifying → idle. `record` is the part to persist after each call.
public struct PasscodeGate: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case waking(since: TimeInterval)
        case awaitingProbe(since: TimeInterval)
        case typing(since: TimeInterval)
        case verifying(since: TimeInterval)
        case ending(AutoUnlockOutcome)
    }

    public let udid: String
    public private(set) var record: AutoUnlockRecord
    private(set) var phase: Phase = .idle
    private var watch = LockWatch()
    private var sawLocked = false
    /// Start of the first unlocked reading after typing.
    private var firstUnlockedAt: TimeInterval?
    /// The first key may have left after firstKeyMaxSec.
    private var lateKeys = false

    public init(udid: String, history: AutoUnlockRecord) {
        self.udid = udid
        self.record = history
    }

    /// True from the wake until the attempt has finished.
    public var inProgress: Bool { phase != .idle }

    /// The latest reading, unknown ones included.
    public var latest: LockSample? { watch.latest }

    /// A person turned it on or off. A pending attempt still finishes.
    public mutating func setEnabled(_ on: Bool, by: AutoUnlockChangeSource, wallNow: Date) {
        if on { record.enable(by: by, at: wallNow) } else { record.disable(reason: nil, by: by, at: wallNow) }
    }

    /// A clicked passcode was typed and the phone stayed locked: the
    /// file's value is probably wrong, so the same rule turns auto off.
    public mutating func clickFailed(wallNow: Date) {
        record.disable(reason: .stillLocked, by: .failure, at: wallNow)
    }

    /// A person's clicked passcode went out. It spends this episode's
    /// try and counts toward the gap and the cap, since it read the same
    /// file: a wrong click must not be followed by the same wrong value.
    public mutating func clickTyped(wallNow: Date) {
        record.episodeAttempted = true
        record.prune(wallNow: wallNow)
        record.attempts.append(wallNow)
        record.attempts = Array(record.attempts.suffix(AutoUnlockRecord.maxKeptAttempts))
    }

    /// Could this gate still type for the current lock? Keeps the Mac
    /// awake only that long (SleepPolicy), never for good.
    public func mayStillAct(now: TimeInterval) -> Bool {
        if inProgress { return true }
        guard record.enabled, !record.episodeAttempted, let start = watch.episodeStart else { return false }
        return now - start <= AutoUnlockTiming.keepAwakeLockedSec
    }

    /// Feed every lock reading, in the order the probes started.
    public mutating func reading(_ r: LockReading, startedAt: TimeInterval) {
        // An out-of-order reading is dropped, so it ends nothing.
        let accepted = watch.latest.map { startedAt >= $0.startedAt } ?? true
        watch.record(r, startedAt: startedAt)
        guard accepted else { return }
        if r == .unlocked { record.episodeAttempted = false }
        if case .verifying(let since) = phase, startedAt >= since {
            if r == .locked, startedAt <= since + AutoUnlockTiming.verifySec { sawLocked = true }
            // Kept even after the window: then it reads as unlockedLate.
            if r == .unlocked, firstUnlockedAt == nil { firstUnlockedAt = startedAt }
        }
    }

    /// What to do now. Call on every reading and on the app's timer.
    public mutating func decide(_ c: PasscodeGateContext, now: TimeInterval, wallNow: Date) -> PasscodeGateStep {
        switch phase {
        case .idle: return decideIdle(c, now: now, wallNow: wallNow)
        case .waking(let since):
            // A wake sends no digits: a stuck one ends unsent.
            if now - since > AutoUnlockTiming.sendDeadlineSec { return finish(.aborted(.sendStuck), wallNow: wallNow) }
            return .nothing(.inProgress)
        case .typing(let since):
            // Keys may be out: a stuck SEND fails closed.
            if now - since > AutoUnlockTiming.sendDeadlineSec { return finish(.unverified, wallNow: wallNow) }
            return .nothing(.inProgress)
        case .awaitingProbe(let since): return decideAfterWake(c, since: since, now: now, wallNow: wallNow)
        case .verifying(let since): return decideVerify(c, since: since, now: now, wallNow: wallNow)
        case .ending(let outcome):
            return finish(outcome, wallNow: wallNow)
        }
    }

    /// An unlock proves the code only when seen soon after typing; one
    /// seen later may be a person's Face ID, so it turns auto off.
    private mutating func decideVerify(_ c: PasscodeGateContext, since: TimeInterval, now: TimeInterval,
                                       wallNow: Date) -> PasscodeGateStep {
        if let u = firstUnlockedAt {
            if u - since > AutoUnlockTiming.verifyProvenSec { return finish(.unlockedLate, wallNow: wallNow) }
            return finish(lateKeys ? .lateFirstKey : .unlocked, wallNow: wallNow)
        }
        if now - since < AutoUnlockTiming.verifySec { return .verifyProbe }
        // A probe started inside the window may still answer.
        if let p = c.probeInFlightSince, p >= since, p <= since + AutoUnlockTiming.verifySec,
           now - p <= AutoUnlockTiming.probeTimeoutSec + 1 {
            return .nothing(.inProgress)
        }
        return finish(sawLocked ? .stillLocked : .unverified, wallNow: wallNow)
    }

    private mutating func decideIdle(_ c: PasscodeGateContext, now: TimeInterval, wallNow: Date) -> PasscodeGateStep {
        if !c.enabled || !record.enabled { return .nothing(.disabled) }
        if !c.paired { return .nothing(.notPaired) }
        if !c.attached { return .nothing(.notAttached) }
        if c.macAsleep { return .nothing(.macAsleep) }
        if c.sheetUp { return .nothing(.sheet) }
        if c.wdaUp { return .nothing(.wdaUp) }
        if c.keyboardBusy { return .nothing(.keyboardBusy) }
        if c.clickChecking { return .nothing(.clickChecking) }
        guard let r = watch.latest, now - r.startedAt <= AutoUnlockTiming.freshProbeSec else { return .probe }
        if r.reading == .unknown { return .nothing(.lockUnknown) }
        if r.reading == .unlocked { return .nothing(.unlocked) }
        guard let start = watch.episodeStart, now - start >= AutoUnlockTiming.settleSec else {
            return .nothing(.settling)
        }
        if record.episodeAttempted { return .nothing(.triedThisEpisode) }
        record.prune(wallNow: wallNow)
        // A future attempt counts as just now (fails closed).
        if let last = record.attempts.last, wallNow.timeIntervalSince(last) < AutoUnlockTiming.minGapSec {
            return .nothing(.tooSoon)
        }
        if record.attempts.count >= AutoUnlockTiming.maxPerHour { return .nothing(.hourlyCap) }
        return .wake
    }

    private mutating func decideAfterWake(_ c: PasscodeGateContext, since: TimeInterval, now: TimeInterval,
                                          wallNow: Date) -> PasscodeGateStep {
        if !c.enabled || !record.enabled { return finish(.aborted(.disabled), wallNow: wallNow) }
        if c.sheetUp { return finish(.aborted(.sheet), wallNow: wallNow) }
        if c.wdaUp { return finish(.aborted(.wdaUp), wallNow: wallNow) }
        if c.keyboardBusy { return finish(.aborted(.keyboardBusy), wallNow: wallNow) }
        if c.clickChecking { return finish(.aborted(.clickChecking), wallNow: wallNow) }
        if !c.paired { return finish(.aborted(.notPaired), wallNow: wallNow) }
        if !c.attached { return finish(.aborted(.notAttached), wallNow: wallNow) }
        // Only a reading taken after the wake ended counts.
        if let r = watch.latest, r.startedAt >= since {
            switch r.reading {
            case .unlocked: return finish(.unlockedBeforeTyping, wallNow: wallNow)
            case .unknown: return finish(.aborted(.lockUnknown), wallNow: wallNow)
            case .locked where now - r.startedAt <= AutoUnlockTiming.freshProbeSec:
                phase = .typing(since: now)
                return .type(AutoTypeApproval(udid: udid, readingStartedAt: r.startedAt))
            case .locked: break   // too old to type on: probe again
            }
        }
        if now - since > AutoUnlockTiming.postWakeProbeDeadlineSec {
            return finish(.aborted(.probeTimeout), wallNow: wallNow)
        }
        return .probe
    }

    /// The wake is about to go out. The attempt counts from here, and
    /// pending is set so a crash before the end turns auto off.
    public mutating func wakeStarted(now: TimeInterval, wallNow: Date) {
        guard phase == .idle else { return }
        record.prune(wallNow: wallNow)
        record.attempts.append(wallNow)
        record.attempts = Array(record.attempts.suffix(AutoUnlockRecord.maxKeptAttempts))
        record.pendingSince = wallNow
        record.episodeAttempted = true
        phase = .waking(since: now)
    }

    /// The wake finished. A failed wake sent no digits, so it ends the
    /// attempt without turning auto off.
    public mutating func wakeEnded(now: TimeInterval, failure: KeyboardFailure? = nil) {
        guard case .waking = phase else { return }
        phase = failure.map { .ending(.notSent($0)) } ?? .awaitingProbe(since: now)
    }

    /// The passcode SEND finished. Only readings started after this count.
    /// `firstKeyAgeSec` is FirstKeyAge's answer; nil reads as too old.
    public mutating func typingEnded(_ r: TypeResult, now: TimeInterval, firstKeyAgeSec: TimeInterval?) {
        guard case .typing = phase else { return }
        switch r {
        case .notSent(let f):
            phase = .ending(.notSent(f))
        case .sent, .maybeSent:
            sawLocked = false
            firstUnlockedAt = nil
            lateKeys = (firstKeyAgeSec ?? .infinity) > AutoUnlockTiming.firstKeyMaxSec
            phase = .verifying(since: now)
        }
    }

    private mutating func finish(_ outcome: AutoUnlockOutcome, wallNow: Date) -> PasscodeGateStep {
        phase = .idle
        record.pendingSince = nil
        if outcome.disables { record.disable(reason: outcome.reason, by: .failure, at: wallNow) }
        return .finished(outcome)
    }
}

/// Checks a clicked passcode the same way: if the phone was locked just
/// before the click, readings for 15 s after typing must show it unlocked.
public struct ClickVerify: Equatable, Sendable {
    public let since: TimeInterval
    private var sawLocked = false
    private var sawUnlocked = false

    /// Nil when the last reading before the click was not a recent lock.
    public init?(typedAt: TimeInterval, lastBefore: LockSample?) {
        guard let s = lastBefore, s.reading == .locked,
              typedAt - s.startedAt <= AutoUnlockTiming.lockFreshSec else { return nil }
        since = typedAt
    }

    public mutating func reading(_ r: LockReading, startedAt: TimeInterval) {
        guard startedAt >= since, startedAt <= since + AutoUnlockTiming.verifySec else { return }
        if r == .locked { sawLocked = true }
        if r == .unlocked { sawUnlocked = true }
    }

    /// Nil while still checking.
    public func outcome(now: TimeInterval) -> AutoUnlockOutcome? {
        if sawUnlocked { return .unlocked }
        if now - since < AutoUnlockTiming.verifySec { return nil }
        return sawLocked ? .stillLocked : .unverified
    }
}
