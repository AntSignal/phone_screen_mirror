import Foundation

/// Decides whether one phone's USB reset needs its chain restarted.
///
/// A phone drops off USB for a few seconds whenever its developer session
/// changes: our own tunnel or runner starting or stopping, devicectl, a dying
/// runner. Restarting on every reset would loop on the resets the restart
/// itself causes. So a reset restarts the chain only when it is not ours,
/// WDA was up before it, and WDA fails a probe once the phone is back.
/// Times are monotonic seconds (systemUptime).
public struct USBResetWatch: Equatable, Sendable {
    /// Our own start or stop resets USB within a few seconds (4 s measured).
    public static let selfInflictedSec: TimeInterval = 10
    /// At most one reset-driven restart per phone in this long.
    public static let restartCooldownSec: TimeInterval = 30
    /// A phone away this long is not coming back by itself; judge anyway.
    public static let maxAbsenceSec: TimeInterval = 15

    public private(set) var lastOwnChangeAt: TimeInterval?
    /// Has WDA answered since our last start or stop? If not, it is still
    /// booting, and the recovery ladder owns it.
    public private(set) var answeredSinceOwnChange = false
    public private(set) var suspect = false
    /// When the phone left USB; nil while it is attached.
    public private(set) var absentSince: TimeInterval?
    public private(set) var lastResetRestartAt: TimeInterval?

    public init() {}

    /// We started or stopped this phone's runner, chain or the tunnel.
    public mutating func noteOwnUSBChange(now: TimeInterval) {
        lastOwnChangeAt = now
        answeredSinceOwnChange = false
        suspect = false
        absentSince = nil
    }

    /// The phone left USB. True if this reset is now under suspicion.
    @discardableResult
    public mutating func onDetached(now: TimeInterval) -> Bool {
        if let own = lastOwnChangeAt, now - own < Self.selfInflictedSec { return false }
        guard answeredSinceOwnChange || suspect else { return false }
        suspect = true
        if absentSince == nil { absentSince = now }
        return true
    }

    /// The phone is back on USB. True if a probe should now decide.
    public mutating func onReattached(now: TimeInterval) -> Bool {
        absentSince = nil
        return suspect
    }

    /// A health probe finished. True means restart the chain now.
    public mutating func onProbe(answered: Bool, now: TimeInterval) -> Bool {
        if answered {
            answeredSinceOwnChange = true
            suspect = false
            return false
        }
        guard suspect else { return false }
        // A probe while the phone is away proves nothing.
        if let away = absentSince, now - away < Self.maxAbsenceSec { return false }
        if let last = lastResetRestartAt, now - last < Self.restartCooldownSec { return false }
        lastResetRestartAt = now
        noteOwnUSBChange(now: now)
        return true
    }
}

/// True when an IOKit USB serial number names this go-ios UDID. Newer phones'
/// serials are the UDID without its dash ("00008140000642…"); older phones'
/// are the 40-hex UDID itself, sometimes in another case.
public func usbSerial(_ serial: String, matchesUDID udid: String) -> Bool {
    let a = serial.replacingOccurrences(of: "-", with: "").uppercased()
    let b = udid.replacingOccurrences(of: "-", with: "").uppercased()
    return !a.isEmpty && a == b
}
