import Foundation

// When iMirror keeps the Mac awake. A sleeping Mac drops every phone's USB
// link, so an agent mid-run comes back to dead chains. But holding the Mac
// awake all day for an idle mirror is rude, so the hold is narrow: automation
// on, and either a client used a phone recently or a phone is recovering.

/// Tells client traffic through a phone's relay apart from the app's own
/// requests (the 3 s health probe goes through the relay too).
///
/// It compares two running totals: requests the relay saw, and requests the
/// app sent. The app counts its own before sending, so the difference never
/// overstates client traffic; a new high in it means a client sent something.
public struct RelayTrafficMeter: Equatable, Sendable {
    private var highWater = 0
    /// Uptime when client traffic was last seen; nil if never.
    public private(set) var lastTrafficAt: TimeInterval?

    public init() {}

    public mutating func sample(relayRequests: Int, ownRequests: Int, now: TimeInterval) {
        let foreign = relayRequests - ownRequests
        if foreign > highWater {
            highWater = foreign
            lastTrafficAt = now
        }
    }
}

public enum SleepPolicy {
    /// Client traffic this recent keeps the Mac awake.
    public static let trafficWindowSec: TimeInterval = 300

    /// Should the PreventSystemSleep assertion be held now?
    public static func keepAwake(automationOn: Bool, lastTrafficAt: TimeInterval?,
                                 recovering: Bool, now: TimeInterval) -> Bool {
        guard automationOn else { return false }
        if recovering { return true }
        guard let at = lastTrafficAt else { return false }
        return now - at <= trafficWindowSec
    }

    /// Is a phone with this reason mid-recovery? A give-up waits minutes for
    /// its retry, so it doesn't count; the ladder bounds all the others.
    public static func isRecovering(_ reason: DeviceReason?) -> Bool {
        guard let reason else { return false }
        return reason != .gaveUp && reason != .macAsleep
    }
}
