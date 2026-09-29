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

/// What the MJPEG partial-wedge watchdog should do. WDA's `/status` can stay
/// healthy while its MJPEG stream has silently died, so `health == .connected`
/// alone doesn't guarantee frames are actually arriving.
public enum MjpegRecoveryAction: Equatable {
    /// Still within the no-frame threshold — could just be a quiet screen.
    case wait
    /// Past the threshold for the first time: bounce the cheap thing first,
    /// the `forward` child carrying the MJPEG port.
    case bounceForward
    /// Still no frames after the bounce: this is more than a dropped forward
    /// socket — escalate to a full chain-level recovery.
    case escalate
}

/// `noFrameForSec` is how long it's been since the last MJPEG frame arrived,
/// on a monotonic clock. `alreadyBounced` is whether `bounceForward` already
/// fired for this stall. `thresholdSec` is how long to wait before acting.
public func nextMjpegRecoveryAction(noFrameForSec: TimeInterval, alreadyBounced: Bool, thresholdSec: TimeInterval) -> MjpegRecoveryAction {
    guard noFrameForSec >= thresholdSec else { return .wait }
    return alreadyBounced ? .escalate : .bounceForward
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
    /// Stop retrying this phone until the user asks.
    case giveUp
}

/// The per-phone ladder. `stage` is 0 before any restart for this outage, 1
/// after this phone's own chain restart, 2 after a tunnel restart. With one
/// phone attached it reproduces the single-phone ladder exactly: one full
/// restart (stage 0 → 2), then give up.
public func nextDeviceRecoveryAction(downForSec: TimeInterval, graceSec: TimeInterval, stage: Int,
                                     othersHealthy: Bool, tunnelHasDevice: Bool) -> DeviceRecoveryAction {
    guard downForSec >= graceSec else { return .wait }
    switch stage {
    case ...0:
        return (othersHealthy && tunnelHasDevice) ? .restartDeviceChain : .restartTunnelAndChains
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
    /// Set on give-up: no automatic retries until the user asks (forceRetry).
    public private(set) var hardStopped = false
    /// Once WDA has been up, an outage is a mid-session wedge: it gets the
    /// short grace, and its clock starts when health drops (a hung runwda
    /// never respawns, so nothing else would start it).
    public private(set) var hadSuccessfulConnection = false

    public init() {}

    /// Health went green: the next outage starts a fresh stage-0 grace.
    public mutating func onConnected() {
        wedgeSince = nil
        stage = 0
        hardStopped = false
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
    }

    /// The user tapped retry after a give-up.
    public mutating func forceRetry(now: TimeInterval) {
        hardStopped = false
        stage = 0
        wedgeSince = now
    }

    /// Something outside the ladder (the MJPEG watchdog) restarted the chain.
    public mutating func noteOutsideRestart() { stage = max(stage, 1) }

    public mutating func hardStop() { hardStopped = true }

    /// Decide what to do now. Call only while this phone's health is down.
    public mutating func tick(now: TimeInterval, othersHealthy: Bool,
                              tunnelHasDevice: Bool) -> DeviceRecoveryAction {
        guard !hardStopped, let since = wedgeSince else { return .wait }
        let grace = chainRecoveryGraceSec(stage: stage, postConnectionOutage: hadSuccessfulConnection)
        let action = nextDeviceRecoveryAction(downForSec: now - since, graceSec: grace, stage: stage,
                                              othersHealthy: othersHealthy,
                                              tunnelHasDevice: tunnelHasDevice)
        switch action {
        case .wait: break
        case .restartDeviceChain: stage = 1
        case .restartTunnelAndChains: stage = 2
        case .giveUp: hardStopped = true
        }
        return action
    }
}
