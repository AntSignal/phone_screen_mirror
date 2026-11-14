import Foundation

/// Outcome of checking/installing the WebDriverAgent runner on the device.
public enum RunnerInstall: Equatable {
    case alreadyPresent          // runner already on the device — nothing to do
    case installed               // we just installed the bundled ipa
    case noBundle                // dev build ships no ipa; assume external install
    case failed(RunnerInstallError)
}

/// Why an `ios install` attempt failed, classified from go-ios's stderr so the UI
/// can give guidance specific to the fix.
public enum RunnerInstallError: Equatable {
    case notProvisioned(raw: String)   // ipa isn't code-signed for this device's UDID
    case deviceLocked(raw: String)     // phone is locked / needs the passcode
    case other(raw: String)            // anything we can't confidently classify

    /// go-ios's own words, trimmed and capped.
    public var raw: String {
        switch self {
        case .notProvisioned(let r), .deviceLocked(let r), .other(let r): return r
        }
    }
}

/// Progress of the runner check/install, emitted to the app so it can reflect
/// state in the status line + health dot.
public enum RunnerInstallEvent: Equatable {
    case checking
    case installing
    /// Replacing an older runner. The new one can raise the XCTest
    /// "Enable UI Automation" passcode sheet once.
    case upgrading(from: String, to: String)
    /// The upgrade failed; the older runner stays and is used.
    case upgradeFailed(kept: String, raw: String)
    case done(RunnerInstall)
    /// The chain restarted while this install ran. Its own `.done` will
    /// never be shown, so the UI must stop saying "Installing…".
    case abandoned
}

/// Decides which runner-install events reach the UI. A bring-up the chain
/// has replaced (a restart or stop bumped its generation) must not report:
/// its late "install failed" would mark the fresh chain down. But when the
/// UI saw that install start, it is told the install was abandoned, or the
/// phone would show "Installing…", with its health probe off, for good.
/// Ported from upstream fed3fb9's generation check on emitInstall.
public struct InstallEventGate: Equatable, Sendable {
    /// The UI has seen an install or upgrade start and not its end.
    public private(set) var installShowing = false

    public init() {}

    /// Should `event`, from the bring-up of generation `from`, reach the
    /// UI while the chain is at generation `current`?
    public mutating func pass(_ event: RunnerInstallEvent, from: Int, current: Int) -> Bool {
        guard from == current else { return false }
        switch event {
        case .installing, .upgrading: installShowing = true
        case .done, .abandoned: installShowing = false
        case .checking, .upgradeFailed: break
        }
        return true
    }

    /// The chain moved to a new generation. True when the UI must now be
    /// sent `.abandoned`.
    public mutating func superseded() -> Bool {
        defer { installShowing = false }
        return installShowing
    }
}

/// Map go-ios `install` stderr to a classified error. Pure so it's unit-testable
/// without a device. Matching is case-insensitive substring — deliberately loose,
/// since go-ios surfaces the underlying MobileInstallation text which varies by
/// iOS version; unknown text falls back to `.other` with the raw message.
public func classifyInstallError(_ stderr: String) -> RunnerInstallError {
    let raw = trimmedRaw(stderr)
    let s = raw.lowercased()

    // Locked first: a locked device is the most actionable and its wording is
    // distinct ("device locked", "please unlock", "passcode").
    if s.contains("lock") || s.contains("passcode") || s.contains("unlock") {
        return .deviceLocked(raw: raw)
    }
    // Provisioning / code-signing mismatch for this device.
    let provisioningSignals = [
        "provision", "eligible", "not eligible", "entitlement",
        "verification", "applicationverificationfailed",
        "no profile", "0xe8008015", "0xe8008016",
    ]
    if provisioningSignals.contains(where: s.contains) {
        return .notProvisioned(raw: raw)
    }
    return .other(raw: raw)
}

/// Whether runwda should be launched given the install result. A failed install
/// with the runner still absent short-circuits — launching runwda would only
/// fail-loop. Everything else (present, freshly installed, or a dev build with no
/// bundled ipa where the runner may have been installed externally) proceeds.
public func shouldSpawnRunwda(after result: RunnerInstall) -> Bool {
    switch result {
    case .alreadyPresent, .installed, .noBundle:
        return true
    case .failed:
        return false
    }
}

// MARK: - Runner upgrade

/// What to do about the phone's runner.
public enum RunnerAction: Equatable {
    case install    // not on the phone
    case upgrade    // the phone's copy is older than the bundled one
    case keep       // up to date, newer, or nothing to compare against
}

/// The version of `bundleId` in `ios apps --list` output, whose lines are
/// "<bundle id> <name> <short version>". The name may hold spaces, so the
/// version is what follows the last space. nil when the app is not listed;
/// "" when it is listed without a version.
public func runnerVersion(inAppsList out: String, bundleId: String) -> String? {
    for line in out.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.first.map(String.init) == bundleId else { continue }
        return fields.count >= 3 ? String(fields[fields.count - 1]) : ""
    }
    return nil
}

/// Install, upgrade or keep. Never downgrades, so two app builds with
/// different bundled runners do not reinstall back and forth. A version
/// whose upgrade already failed on this chain is not tried again: each
/// attempt can reset the phone's USB and raise the passcode sheet.
public func runnerAction(installed: String?, bundled: String?,
                         failedUpgradeTo: String? = nil) -> RunnerAction {
    guard let installed else { return .install }
    guard let bundled, !bundled.isEmpty, bundled != failedUpgradeTo else { return .keep }
    return isVersion(installed, olderThan: bundled) ? .upgrade : .keep
}

/// Dotted numeric compare. A missing or non-numeric part counts as 0, so
/// "16.14.2" equals "16.14.2.0" and "" is older than "1".
public func isVersion(_ a: String, olderThan b: String) -> Bool {
    let pa = a.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    let pb = b.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y }
    }
    return false
}

/// The result of an upgrade attempt. A failed upgrade leaves the older
/// runner on the phone, so runwda can still start with it.
public func upgradeResult(_ install: RunnerInstall) -> RunnerInstall {
    if case .failed = install { return .alreadyPresent }
    return install
}

/// Trim whitespace and cap length so a runaway error string can't bloat the UI.
private func trimmedRaw(_ s: String, cap: Int = 300) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count <= cap ? t : String(t.prefix(cap)) + "…"
}
