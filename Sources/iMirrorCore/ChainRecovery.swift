import Foundation

/// Pure decision logic for the app-level WDA recovery ladder (`main.swift`'s
/// `runWatchdog`) and the MJPEG partial-wedge watchdog. `ManagedProcess`
/// (see `ManagedProcessLiveness.swift`) already recovers a wedged `runwda` on
/// its own by killing it past a readiness deadline; these functions cover
/// what's above that: what to do when runwda's own respawns still aren't
/// bringing WDA back, and what to do when the WDA HTTP session is healthy but
/// the MJPEG video stream has gone quiet.

/// What the chain-level watchdog should do about a WDA outage.
public enum ChainRecoveryAction: Equatable {
    /// Still within grace — a `ManagedProcess` readiness cycle may still recover it.
    case wait
    /// One readiness cycle wasn't enough; tear down and rebuild the whole chain.
    case restartChain
    /// A full chain restart wasn't enough either — this isn't self-healing.
    /// Stop retrying automatically until the user explicitly asks again.
    case giveUp
}

/// `downForSec` is measured on a monotonic clock since automation turned on
/// or since the last `restartChain`. `stage` is 0 before any restart has been
/// attempted for this outage, 1 after one `restartChain`. `graceSec` is how
/// long each stage gets before escalating — long enough to cover one
/// `ManagedProcess` readiness cycle plus WDA's own boot time.
public func nextChainRecoveryAction(downForSec: TimeInterval, stage: Int, graceSec: TimeInterval) -> ChainRecoveryAction {
    guard downForSec >= graceSec else { return .wait }
    return stage <= 0 ? .restartChain : .giveUp
}

/// How long stage 0 of the ladder should wait before escalating.
///
/// A mid-session wedge (WDA was up, then hung, `postConnectionOutage ==
/// true`) can't be caught by `ManagedProcess`'s one-shot readiness poll —
/// that poll only guards a fresh spawn, and a hung-but-still-running
/// `runwda` never exits to trigger one. So at stage 0 with a real prior
/// connection, escalate quickly (~30s) rather than waiting out a full boot
/// window for a recovery path that was never going to fire.
///
/// Every other case — initial boot (`postConnectionOutage == false`) or a
/// fresh chain brought up by a restart (stage >= 1) — needs the full
/// tunnel + runner-install + WDA-boot cycle, so it gets the longer ~90s
/// grace regardless of `postConnectionOutage`.
public func chainRecoveryGraceSec(stage: Int, postConnectionOutage: Bool) -> TimeInterval {
    (stage == 0 && postConnectionOutage) ? 30 : 90
}

/// What the MJPEG watchdog should do when the video stops. WDA's `/status`
/// can stay healthy while its MJPEG stream has silently died, so a healthy
/// health dot doesn't prove frames are arriving.
public enum MjpegRecoveryAction: Equatable {
    case wait
    /// Bounce the cheap thing: the `forward` child carrying the MJPEG port.
    case bounceForward
}

/// How long between forward bounces while the video stays stalled.
public let mjpegRebounceSec: TimeInterval = 60

/// Only ever bounces the MJPEG forward, and only while `/status` answers.
/// It used to restart, then hard-stop, a WDA agents were still driving; a
/// WDA that doesn't answer belongs to the ladder. `sinceBounceSec` is nil
/// before this stall's first bounce.
public func nextMjpegRecoveryAction(noFrameForSec: TimeInterval, sinceBounceSec: TimeInterval?,
                                    statusAnswers: Bool, thresholdSec: TimeInterval,
                                    rebounceSec: TimeInterval = mjpegRebounceSec) -> MjpegRecoveryAction {
    guard statusAnswers, noFrameForSec >= thresholdSec else { return .wait }
    guard let since = sinceBounceSec else { return .bounceForward }
    return since >= rebounceSec ? .bounceForward : .wait
}

// MARK: - Health probes

/// How one health probe of `/status` ended.
public enum ProbeOutcome: Equatable, Sendable {
    case answered
    /// Refused, reset, not ready, or any error other than a timeout.
    case failed
    case timedOut
}

/// Turns probe outcomes into a health call. One timed-out probe behind an
/// agent's slow `/source` used to mark a phone down and get its WDA
/// restarted. Now down takes two failures in a row, and a timeout while
/// other requests wait on WDA is "busy", which counts for nothing.
public struct ProbeStrikes: Equatable, Sendable {
    public enum Call: Equatable, Sendable {
        case up
        /// No verdict: WDA is serving someone else. Keep the current health.
        case busy
        /// One failure. Keep the current health and look again.
        case suspect
        case down
    }

    public static let failuresForDown = 2
    /// Busy longer than this is stuck, not slow. The MCP's longest wait is 60 s.
    public static let maxBusySec: TimeInterval = 75

    public private(set) var failures = 0
    /// When the current busy run began; nil when the last probe wasn't busy.
    public private(set) var busySince: TimeInterval?

    public init() {}

    /// `inFlightAtSend` is how many requests were waiting on WDA through the
    /// relay when the probe was sent, not counting the probe itself.
    public mutating func record(_ outcome: ProbeOutcome, inFlightAtSend: Int,
                                now: TimeInterval) -> Call {
        switch outcome {
        case .answered:
            failures = 0
            busySince = nil
            return .up
        case .timedOut where inFlightAtSend > 0:
            let since = busySince ?? now
            busySince = since
            if now - since < Self.maxBusySec { return .busy }
            return strike()
        case .timedOut, .failed:
            busySince = nil
            return strike()
        }
    }

    private mutating func strike() -> Call {
        failures += 1
        return failures >= Self.failuresForDown ? .down : .suspect
    }
}

/// Which connections through one phone's relay have a request waiting on WDA.
/// A request waits from the client's bytes until WDA's first reply bytes,
/// which holds for HTTP/1.1 with or without keep-alive. Connection ids are
/// the relay's own.
public struct InFlightRequests: Equatable, Sendable {
    private var waiting: Set<Int> = []

    public init() {}

    public var count: Int { waiting.count }

    public mutating func clientSent(_ id: Int) { waiting.insert(id) }
    public mutating func backendSent(_ id: Int) { waiting.remove(id) }
    public mutating func closed(_ id: Int) { waiting.remove(id) }
}

// MARK: - Several phones

/// What one phone's watchdog should do about its WDA outage when several
/// phones share the Mac's single go-ios tunnel.
///
/// The tunnel is the expensive lever: restarting it drops WDA on EVERY phone
/// (each one then needs its own ~20s boot, and any restart risks wedging a
/// healthy phone's testmanagerd). So a phone first restarts only its own chain,
/// and pulls the tunnel only when that is clearly the problem (the tunnel lists
/// no route to this phone) or costs nobody anything (no other phone is up).
public enum DeviceRecoveryAction: Equatable, Sendable {
    case wait
    /// Restart this phone's runwda + forwards; the tunnel and other phones stay up.
    case restartDeviceChain
    /// Restart the shared tunnel, then every phone's chain.
    case restartTunnelAndChains
    /// Stop the children for a while; the ladder retries later by itself.
    case giveUp
    /// A give-up's wait is over: restart this phone's chain and try again.
    case autoRetry
}

/// The per-phone ladder. `stage` is 0 before any restart for this outage, 1
/// after this phone's own chain restart, 2 after a tunnel restart. Its own
/// chain goes first whenever the tunnel lists the phone, even with no other
/// phone up: the tunnel is rarely at fault then, and its restart is slower
/// and resets the phone's USB once more.
public func nextDeviceRecoveryAction(downForSec: TimeInterval, graceSec: TimeInterval, stage: Int,
                                     othersHealthy: Bool, tunnelHasDevice: Bool) -> DeviceRecoveryAction {
    guard downForSec >= graceSec else { return .wait }
    switch stage {
    case ...0:
        return tunnelHasDevice ? .restartDeviceChain : .restartTunnelAndChains
    case 1:
        return (!tunnelHasDevice || !othersHealthy) ? .restartTunnelAndChains : .giveUp
    default:
        return .giveUp
    }
}

/// True when a tunnel restart may go ahead: none in the last `minInterval`.
/// Two phones hitting their grace together would otherwise each restart the
/// tunnel, knocking the other's fresh chain down again.
public func shouldRestartTunnel(lastAt: TimeInterval?, now: TimeInterval,
                                minInterval: TimeInterval = 120) -> Bool {
    guard let lastAt else { return true }
    return now - lastAt >= minInterval
}

/// One phone's recovery-ladder state, lifted out of the app delegate so each
/// phone carries its own. Times are monotonic seconds (systemUptime), never
/// wall-clock, so a Mac sleep can't skew them.
public struct ChainLadderState: Equatable, Sendable {
    /// When this outage's grace clock started. Nil = nothing to measure yet.
    public private(set) var wedgeSince: TimeInterval?
    public private(set) var stage = 0
    /// Set on give-up. The ladder retries by itself after a backoff, whether
    /// or not the phone ever worked; a user retry acts at once.
    public private(set) var hardStopped = false
    public private(set) var hardStoppedAt: TimeInterval?
    /// Give-ups since WDA last answered; sets the backoff.
    public private(set) var giveUps = 0
    /// Once WDA has been up, an outage is a mid-session wedge: it gets the
    /// short grace, and its clock starts when health drops (a hung runwda
    /// never respawns, so nothing else would start it).
    public private(set) var hadSuccessfulConnection = false

    /// How long each give-up lasts: 2 min, 5 min, then 10 min for good. Most
    /// outages (a USB reset, a crashed runner, a passcode sheet the user
    /// answers) are gone by then, and an agent has nobody to tap retry.
    public static let autoRetryBackoffSec: [TimeInterval] = [120, 300, 600]

    /// The wait after the `giveUps`-th give-up in a row (1-based).
    public static func autoRetryDelay(afterGiveUps giveUps: Int) -> TimeInterval {
        let i = min(max(giveUps, 1), autoRetryBackoffSec.count) - 1
        return autoRetryBackoffSec[i]
    }

    /// When the ladder will retry by itself; nil unless it has given up.
    public var nextAutoRetryAt: TimeInterval? {
        guard hardStopped, let at = hardStoppedAt else { return nil }
        return at + Self.autoRetryDelay(afterGiveUps: giveUps)
    }

    public init() {}

    /// Health went green: the next outage starts a fresh stage-0 grace.
    public mutating func onConnected() {
        wedgeSince = nil
        stage = 0
        hardStopped = false
        hardStoppedAt = nil
        giveUps = 0
        hadSuccessfulConnection = true
    }

    /// Health went red. Only a mid-session outage starts the clock here —
    /// during first boot, runwda starting does (onRunwdaStarted), so tunnel
    /// and install time don't count against WDA's own boot grace.
    public mutating func onDown(now: TimeInterval) {
        if hadSuccessfulConnection, wedgeSince == nil { wedgeSince = now }
    }

    /// runwda (re)started, including after any restart. Must not touch
    /// `stage`, or the ladder could never advance to give-up.
    public mutating func onRunwdaStarted(now: TimeInterval) { wedgeSince = now }

    /// Automation turned on or off: start clean.
    public mutating func reset() {
        wedgeSince = nil
        stage = 0
        hardStopped = false
        hardStoppedAt = nil
        giveUps = 0
    }

    /// A retry (the user's or the ladder's own) is restarting the chain now.
    /// That restart is this outage's stage-0 step, so the new chain gets the
    /// full boot grace and the next step is the tunnel, not another restart.
    public mutating func forceRetry(now: TimeInterval) {
        hardStopped = false
        hardStoppedAt = nil
        stage = 1
        wedgeSince = now
    }

    /// Something outside the ladder (a USB-reset restart) restarted the
    /// chain. The new runner needs the full boot grace; stage 0's 30 s
    /// would restart it again mid-boot.
    public mutating func noteOutsideRestart() { stage = max(stage, 1) }

    public mutating func hardStop(now: TimeInterval) {
        hardStopped = true
        hardStoppedAt = now
        giveUps += 1
    }

    /// Decide what to do now. Call only while this phone's health is down.
    public mutating func tick(now: TimeInterval, othersHealthy: Bool,
                              tunnelHasDevice: Bool) -> DeviceRecoveryAction {
        if hardStopped {
            guard let at = nextAutoRetryAt, now >= at else { return .wait }
            forceRetry(now: now)
            return .autoRetry
        }
        guard let since = wedgeSince else { return .wait }
        let grace = chainRecoveryGraceSec(stage: stage, postConnectionOutage: hadSuccessfulConnection)
        let action = nextDeviceRecoveryAction(downForSec: now - since, graceSec: grace, stage: stage,
                                              othersHealthy: othersHealthy,
                                              tunnelHasDevice: tunnelHasDevice)
        switch action {
        case .wait: break
        case .restartDeviceChain: stage = 1
        case .restartTunnelAndChains: stage = 2
        case .giveUp: hardStop(now: now)
        case .autoRetry: break
        }
        return action
    }
}
