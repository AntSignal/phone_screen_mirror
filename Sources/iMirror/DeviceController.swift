// DeviceController — one phone's control channel, kept healthy on its own.
//
// Owns the phone's chain (runwda + forwards + relay), a WDAClient on its relay
// port, a 3s health probe and its recovery ladder. Every attached phone has one
// and each keeps running whether or not it is the phone on screen, so an agent
// driving phone2 through the MCP server doesn't depend on the window showing
// phone2. The window (AppDelegate) only renders the selected controller.
//
// Main thread only, except where noted.

import Foundation
import iMirrorCore

final class DeviceController {
    enum Health: Equatable { case down, connecting, connected }

    let udid: String
    let slot: PortSlot
    let wda: WDAClient
    /// nil when there's no go-ios to run one (an external WDA on :8100).
    let chain: DeviceChain?

    var alias: String { didSet { if alias != oldValue { onChange?() } } }
    var attached: AttachedDevice { didSet { if attached != oldValue { onChange?() } } }

    private(set) var health: Health = .down
    private(set) var installingRunner = false
    private(set) var lastRunnerInstall: RunnerInstall?
    /// The runner is installed but can't start (untrusted developer, signing).
    private(set) var unrecoverable = false
    /// The last thing worth telling a user about this phone.
    private(set) var detail: String?
    /// The last error worth publishing (devices.json last_error).
    private(set) var lastError: String?
    /// A USB reset restarted the chain and WDA has not answered since.
    private var usbResetPending = false
    /// Between the Mac's willSleep and didWake; published as mac_asleep.
    private(set) var macAsleep = false { didSet { if macAsleep != oldValue { onChange?() } } }
    private var traffic = RelayTrafficMeter()
    private var published = PublishedState()
    /// What runwda last said needs a person; cleared once WDA answers.
    private(set) var runwdaClass: RunwdaLogClass?
    private var lastDetachEventAt: TimeInterval?
    private(set) var ladder = ChainLadderState()
    private var resetWatch = USBResetWatch()
    private var strikes = ProbeStrikes()
    /// Did the last probe get an answer from /status? The video watchdog
    /// may only bounce the MJPEG forward while it does.
    private(set) var statusAnswers = false

    private var probing = false
    private var creatingSession = false
    private var timer: Timer?
    private var running = false

    /// Lock readings (iMirrorCore/LockProbe.swift); drive the lock hold.
    private(set) var lockWatch = LockWatch()
    private var lockProbing = false
    private var lastLockProbeAt: TimeInterval?
    /// Bumped when a hung probe is given up on; its late answer is dropped.
    private var lockProbeEpoch = 0
    private var lockTimer: Timer?

    // Wired by ChainManager.
    /// Is any OTHER phone connected right now? (The tunnel is shared, so
    /// restarting it costs them their WDA.)
    var othersHealthy: () -> Bool = { false }
    /// Does the shared tunnel list a route to this phone (last poll)?
    var tunnelHasDevice: () -> Bool = { true }
    /// Ask for the shared tunnel (and so every chain) to restart. False when
    /// its cooldown refused, so nothing was restarted.
    var requestTunnelRestart: () -> Bool = { false }
    /// Runs one lock probe off main and answers on main. Nil: no go-ios.
    var probeLock: ((@escaping (LockReading) -> Void) -> Void)?
    /// Every lock reading, after this controller has noted it.
    var onLockReading: ((LockReading, TimeInterval) -> Void)?
    /// Who unlocked the phone: "auto", "click" or "other".
    var unlockCause: () -> String = { "other" }
    /// devices.json auto_unlock; nil for a phone with no keyboard pairing.
    var autoUnlockState: () -> String? = { nil }
    /// Where events go. Tests swap it so nothing reaches the real log.
    var writeEvent: (DeviceEvent) -> Void = { EventLog.shared.write($0) }

    // Observed by the window and the device file.
    var onChange: (() -> Void)?
    /// Every probe result, changed or not (the window's MJPEG watchdog ticks on it).
    var onHealth: ((_ old: Health, _ new: Health) -> Void)?
    var onStatus: ((String) -> Void)?

    init(udid: String, slot: PortSlot, alias: String, attached: AttachedDevice, chain: DeviceChain?) {
        self.udid = udid
        self.slot = slot
        self.alias = alias
        self.attached = attached
        self.chain = chain
        self.wda = WDAClient(base: URL(string: slot.relayURL)!)
        chain?.onRunwdaStarted = { [weak self] in
            // Seed the ladder's clock when runwda actually starts (not at
            // Automation-on), so tunnel and install time don't eat WDA's boot
            // grace. Never touches the ladder's stage.
            self?.ladder.onRunwdaStarted(now: ProcessInfo.processInfo.systemUptime)
        }
        chain?.onRunnerInstall = { [weak self] event in self?.runnerInstall(event) }
        chain?.onOwnUSBChange = { [weak self] in self?.noteOwnUSBChange() }
        chain?.onRunwdaLog = { [weak self] cls, err in self?.runwdaSaid(cls, err) }
        chain?.onWDAUnrecoverable = { [weak self] in
            guard let self, self.running, self.health == .down else { return }
            self.unrecoverable = true
            self.status("WebDriverAgent installed but won't start on \(self.alias) — trust the "
                      + "developer on the phone: Settings ▸ General ▸ VPN & Device Management.")
        }
    }

    // MARK: Lifecycle

    /// Bring the chain up and start probing. `stagger` offsets this phone's
    /// probe so several phones' probes don't all land on the same tick.
    func start(stagger: TimeInterval) {
        guard !running else { return }
        running = true
        ladder.reset()
        strikes = ProbeStrikes()
        statusAnswers = false
        chain?.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + stagger) { [weak self] in
            guard let self, self.running, self.timer == nil else { return }
            self.probeNow()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.probeNow() }
            RunLoop.main.add(t, forMode: .common)   // keep firing during UI tracking
            self.timer = t
        }
        let lt = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.lockTick() }
        RunLoop.main.add(lt, forMode: .common)
        lockTimer = lt
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        lockTimer?.invalidate()
        lockTimer = nil
        chain?.stop()
        let old = health
        health = .down
        installingRunner = false
        if old != .down { onHealth?(old, .down) }
        onChange?()
    }

    // MARK: User and window actions

    /// The health dot was clicked. Normally a re-check; after a give-up it's the
    /// user asking to retry, which re-arms the ladder.
    func userRetry() {
        guard ladder.hardStopped else { probeNow(); return }
        log(.restart, detail: "user retry")
        forgetRunwdaClass()
        ladder.forceRetry(now: ProcessInfo.processInfo.systemUptime)
        unrecoverable = false
        status("Retrying WebDriverAgent on \(alias)…")
        restartOwnOrTunnel()
    }

    /// Settings → Restart: this phone's chain only.
    func restartChain(detail: String = "user restart") {
        log(.restart, detail: detail)
        forgetRunwdaClass()
        ladder.forceRetry(now: ProcessInfo.processInfo.systemUptime)
        unrecoverable = false
        status("Restarting \(alias)'s connection…")
        chain?.restart()
        onChange?()
    }

    /// A client's restart request (B1c), already through the cooldown. Acts
    /// like Settings → Restart: this phone's chain only, never the shared
    /// tunnel, so one session can't take every phone down. Never types a passcode.
    func restartRequested(_ outcome: RestartRequestOutcome) {
        log(.request, detail: outcome.rawValue)
        guard outcome == .accepted else { return }
        restartChain(detail: "request")
    }

    func bounceMJPEGForward() { chain?.bounceMJPEGForward() }

    // MARK: USB resets (rules in iMirrorCore/USBReset.swift)

    /// We changed this phone's USB session (the shared tunnel started).
    func noteOwnUSBChange() {
        resetWatch.noteOwnUSBChange(now: ProcessInfo.processInfo.systemUptime)
    }

    /// IOKit or the poll saw the phone leave USB.
    func usbDetached() {
        guard running, chain != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let suspect = resetWatch.onDetached(now: now)
        // IOKit and the poll both see one reset.
        if let last = lastDetachEventAt, now - last < 5 { return }
        lastDetachEventAt = now
        // Ignored: we caused it, or WDA was not up.
        log(suspect ? .usbReset : .usbResetIgnored, expected: EventLog.shared.resetIsExpected(udid: udid))
    }

    /// The phone is back. If its reset is suspect, probe soon: the probe
    /// decides whether the reset killed the forwards.
    func usbReattached() {
        guard running, resetWatch.onReattached(now: ProcessInfo.processInfo.systemUptime) else { return }
        // usbmux needs a moment to list the phone again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.probeNow() }
    }

    /// A reset killed WDA: rebuild now instead of waiting out the ladder's grace.
    private func restartAfterUSBReset() {
        log(.restart, reason: .usbReset, expected: EventLog.shared.resetIsExpected(udid: udid))
        usbResetPending = true
        // A fresh chain needs 90 s to boot, counted from now.
        ladder.noteOutsideRestart(now: ProcessInfo.processInfo.systemUptime)
        status("\(alias)'s USB connection reset — reconnecting…")
        chain?.restart()
        onChange?()
    }

    /// The shared tunnel was just restarted for everyone: this chain was
    /// rebuilt too, so a give-up here no longer holds and the grace
    /// clock starts again.
    func tunnelRestarted() {
        log(.restart, detail: "shared tunnel restarted")
        ladder.noteTunnelRestart(now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Device file

    /// A recent lock probe said locked.
    var isLocked: Bool { lockWatch.isLocked(now: ProcessInfo.processInfo.systemUptime) }

    var registryState: RegisteredDevice.State {
        // Locked is waiting for a person or auto-unlock, never failed.
        let locked = isLocked
        if (ladder.hardStopped && !locked) || unrecoverable { return .failed }
        switch lastRunnerInstall {
        case .failed(.deviceLocked) where locked: break
        case .failed: return .failed
        default: break
        }
        if installingRunner { return .installing }
        switch health {
        case .connected: return .ready
        case .connecting: return .starting
        case .down: return ladder.hadSuccessfulConnection ? .down : .starting
        }
    }

    var reason: DeviceReason? {
        deviceReason(DeviceReasonInputs(
            ready: registryState == .ready, runwda: runwdaClass, gaveUp: ladder.hardStopped, macAsleep: macAsleep,
            usbReset: usbResetPending, tunnelHasDevice: chain == nil || tunnelHasDevice(),
            restarting: ladder.stage >= 1, everConnected: ladder.hadSuccessfulConnection, locked: isLocked))
    }

    /// This phone's devices.json entry. Logs a state event when the state
    /// or reason moved since the last write.
    func registryEntry(now: Date) -> RegisteredDevice {
        let state = registryState, why = reason
        if let change = published.update(state: state, reason: why, now: now) {
            log(.state, from: change.from?.rawValue, to: state.rawValue, reason: why,
                detail: state == .ready ? nil : detail)
        }
        let retryAt = isLocked ? nil : ladder.nextAutoRetryAt.map {
            DeviceRegistryCodec.timestamp(now.addingTimeInterval($0 - ProcessInfo.processInfo.systemUptime))
        }
        return RegisteredDevice(
            udid: udid, alias: alias, kind: .device, productType: attached.productType,
            iosVersion: attached.productVersion, connection: attached.connection, slot: slot.index,
            wdaURL: slot.relayURL, mjpegPort: Int(slot.mjpegPort), state: state, detail: detail,
            reason: why?.rawValue, stateSince: published.since.map(DeviceRegistryCodec.timestamp),
            chainEpoch: chain?.epoch, lastError: lastError, nextRetryAt: retryAt,
            autoUnlock: autoUnlockState())
    }

    // MARK: Mac sleep and wake (rules in iMirrorCore/PowerPolicy.swift)

    /// The Mac is going to sleep: its USB goes with it.
    func macWillSleep() {
        log(.sleep)
        macAsleep = true
    }

    /// Sleep dropped USB, so this chain is dead even if a probe hasn't
    /// failed yet. Rebuild now rather than wait out the ladder's grace.
    func macDidWake() {
        log(.wake)
        macAsleep = false
        guard running else { return }
        restartChain(detail: "mac woke")
    }

    /// Uptime of the last client request through this phone's relay.
    func sampleTraffic(now: TimeInterval) -> TimeInterval? {
        guard let chain else { return nil }
        traffic.sample(relayRequests: chain.relayRequestsSeen,
                       ownRequests: wda.requestsSent + chain.readinessRequestsSent, now: now)
        return traffic.lastTrafficAt
    }

    private func log(_ kind: DeviceEventKind, from: String? = nil, to: String? = nil,
                     reason: DeviceReason? = nil, detail: String? = nil, expected: Bool? = nil) {
        writeEvent(DeviceEvent(at: Date(), udid: udid, alias: alias, event: kind,
                               from: from, to: to, reason: reason?.rawValue,
                               detail: detail, expected: expected))
    }

    // MARK: Health probe + recovery ladder

    private func probeNow() {
        guard running, !installingRunner, !probing else { return }
        // Don't probe mid-gesture: the GET would queue behind the /actions on
        // WDA's single XCUITest queue and could time out into a false .down.
        if wda.isGestureInFlight { return }
        probing = true
        // Read before our probe opens, so it never counts itself.
        let inFlightAtSend = chain?.relayInFlight ?? 0
        wda.probe { [weak self] result in          // delivered on main
            guard let self else { return }
            self.probing = false
            guard self.running else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let outcome: ProbeOutcome
            switch result {
            case .alive, .needsSession: outcome = .answered
            case .timedOut: outcome = .timedOut
            case .down: outcome = .failed
            }
            let call = self.strikes.record(outcome, inFlightAtSend: inFlightAtSend, now: now)
            self.statusAnswers = call == .up
            switch call {
            case .up:
                if result == .needsSession { self.createSession() } else { self.setHealth(.connected) }
            case .down:
                self.setHealth(.down)
            case .busy, .suspect:
                self.onHealth?(self.health, self.health)   // no verdict yet
            }
            // A busy WDA says nothing about the USB link.
            if self.chain != nil, call != .busy,
               self.resetWatch.onProbe(answered: call == .up, now: now) {
                self.restartAfterUSBReset()
                return
            }
            self.runWatchdog()
        }
    }

    private func createSession() {
        guard !creatingSession else { return }
        creatingSession = true
        setHealth(.connecting)
        wda.connect { [weak self] result in        // delivered on main
            guard let self else { return }
            self.creatingSession = false
            guard self.running else { return }
            if case .success = result { self.setHealth(.connected) } else { self.setHealth(.down) }
        }
    }

    private func setHealth(_ new: Health) {
        let old = health
        health = new
        switch new {
        case .connected:
            ladder.onConnected()
            unrecoverable = false
            usbResetPending = false
            forgetRunwdaClass()
            // Recovered: "won't start… retrying" would now be a lie.
            if old != .connected { detail = nil; lastError = nil }
        case .connecting:
            break
        case .down:
            ladder.onDown(now: ProcessInfo.processInfo.systemUptime)
        }
        onHealth?(old, new)
        if old != new { onChange?() }
    }

    /// The per-phone ladder (see nextDeviceRecoveryAction in iMirrorCore).
    /// ManagedProcess already respawns a wedged runwda past its readiness
    /// deadline; this covers the respawns not bringing WDA back.
    private func runWatchdog() {
        guard chain != nil, health == .down else { return }
        let afterUnlock = ladder.unlockedAt != nil
        let action = ladder.tick(now: ProcessInfo.processInfo.systemUptime,
                                 othersHealthy: othersHealthy(), tunnelHasDevice: tunnelHasDevice(),
                                 held: chain?.passcodeHeld ?? false, locked: isLocked)
        switch action {
        case .wait:
            break
        case .holdForLock:
            // Restarts can't reach a locked phone; the relay stays up.
            chain?.stopChildren()
            status("\(alias) is locked — "
                 + (autoUnlockState() == AutoUnlockState.on.rawValue
                    ? "auto-unlock is on, so iMirror will type its passcode."
                    : "unlock it and WebDriverAgent comes back by itself."))
            onChange?()
        case .restartDeviceChain where afterUnlock:
            log(.restart, detail: "unlocked")
            status("\(alias) is unlocked — restarting its connection…")
            chain?.restart()
            onChange?()
        case .restartTunnelAndChains where afterUnlock:
            log(.restart, detail: "unlocked")
            status("\(alias) is unlocked — resetting the USB connection…")
            if !requestTunnelRestart() {
                // Cooldown refused: ask again soon, never climb to give-up.
                chain?.restart()
                ladder.tunnelRestartRefusedAfterUnlock(now: ProcessInfo.processInfo.systemUptime)
            }
            onChange?()
        case .autoRetry:
            log(.autoRetry, detail: "after give-up \(ladder.giveUps)")
            // The new runwda reports its own cause. A stale needs_passcode
            // makes clients refuse every restart until WDA answers. The
            // hold stays spent, so this retry is never paused.
            runwdaClass = nil
            unrecoverable = false
            status("Retrying WebDriverAgent on \(alias)…")
            restartOwnOrTunnel(tunnelAllowed: ChainLadderState.retryMayRestartTunnel(
                giveUps: ladder.giveUps, othersHealthy: othersHealthy()))
        case .restartDeviceChain:
            // tick() restarted the clock; onRunwdaStarted restarts it again
            // once the new runwda spawns. A chain that never gets that far
            // still ages from now toward the next stage.
            log(.restart, detail: "ladder: this phone's chain")
            status("WebDriverAgent on \(alias) is taking longer than usual — restarting its connection…")
            chain?.restart()
            onChange?()
        case .restartTunnelAndChains:
            status("WebDriverAgent on \(alias) is taking longer than usual — resetting the USB connection…")
            // The tunnel was just restarted: restart this phone's chain instead.
            if !requestTunnelRestart() {
                log(.restart, detail: "ladder: tunnel busy, this phone's chain")
                chain?.restart()
            }
            onChange?()
        case .giveUp:
            // Stop the children outright, or runwda keeps respawning (and being
            // killed by its readiness deadline) forever after a give-up. The
            // relay stays up, so a retry can bring the chain back.
            chain?.stopChildren()
            let wait = Int(ChainLadderState.autoRetryDelay(afterGiveUps: ladder.giveUps) / 60)
            log(.giveUp, reason: .gaveUp, detail: "retrying in \(wait) min")
            status("WebDriverAgent won't start on \(alias). Retrying in \(wait) min — "
                 + "or tap WDA to retry now.")
            onChange?()
        }
    }

    private func restartOwnOrTunnel(tunnelAllowed: Bool = true) {
        if tunnelHasDevice() || !tunnelAllowed || !requestTunnelRestart() { chain?.restart() }
        onChange?()
    }

    // MARK: Lock probe (rules in iMirrorCore/LockProbe.swift)

    /// Every 5 s while WDA is down and the Mac awake, take a reading.
    /// A ready phone is never probed on this schedule.
    private func lockTick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A probe stuck in the kernel must not stop probing.
        if lockProbing, now - (lastLockProbeAt ?? now) > AutoUnlockTiming.probeTimeoutSec + 5 {
            lockProbing = false
            lockProbeEpoch += 1
        }
        if chain != nil, health != .connected, !macAsleep,
           now - (lastLockProbeAt ?? -.infinity) >= AutoUnlockTiming.probeIntervalSec {
            probeLockNow()
        }
    }

    /// When the probe now running started; nil when none runs.
    var lockProbeInFlightSince: TimeInterval? { lockProbing ? lastLockProbeAt : nil }

    /// One probe now, unless one is already running for this phone.
    func probeLockNow() {
        guard running, let probeLock, !lockProbing else { return }
        lockProbing = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        lastLockProbeAt = startedAt
        let epoch = lockProbeEpoch
        probeLock { [weak self] r in
            guard let self, epoch == self.lockProbeEpoch else { return }
            self.lockProbing = false
            guard self.running else { return }
            self.lockRead(r, startedAt: startedAt)
        }
    }

    /// Note a reading. Auto-unlock sees it first, so its own events come
    /// before the lock event and the restart. An unlock re-arms the
    /// ladder and restarts the chain at once.
    func lockRead(_ r: LockReading, startedAt: TimeInterval) {
        let wasLocked = isLocked
        let change = lockWatch.record(r, startedAt: startedAt)
        onLockReading?(r, startedAt)
        switch change {
        case .becameLocked?:
            log(.lock, detail: "locked")
        case .becameUnlocked?:
            writeEvent(DeviceEvent(at: Date(), udid: udid, alias: alias, event: .lock,
                                   reason: unlockCause(), detail: "unlocked"))
            // With WDA up there is nothing to bring back.
            if health != .connected { ladder.noteUnlocked(now: ProcessInfo.processInfo.systemUptime) }
            // Only the lock's own trace; a passcode-sheet hold stays.
            if runwdaClass == .locked { runwdaClass = nil }
            if case .failed(.deviceLocked)? = lastRunnerInstall { lastRunnerInstall = nil }
        case nil:
            break
        }
        if change != nil || wasLocked != isLocked {
            if health == .down { runWatchdog() }
            onChange?()
        }
    }

    /// runwda's output named a cause and/or an error (DeviceChain.runwdaSaid).
    private func runwdaSaid(_ cls: RunwdaLogClass?, _ err: String?) {
        guard running else { return }
        if let err { lastError = err }
        if let cls, cls != runwdaClass, health != .connected {
            runwdaClass = cls
            status(Self.runwdaMessage(cls, alias: alias))
        }
        onChange?()
    }

    private func forgetRunwdaClass() {
        runwdaClass = nil
        chain?.clearPasscodeHold()
    }

    static func runwdaMessage(_ cls: RunwdaLogClass, alias: String) -> String {
        switch cls {
        case .needsPasscode:
            return "\(alias) is asking for its passcode to allow UI Automation — enter it on the "
                 + "phone. WebDriverAgent starts by itself once it is answered."
        case .locked:
            return "\(alias) is locked — unlock it and WebDriverAgent comes back by itself."
        case .untrusted:
            return "\(alias) doesn't trust this Mac or WebDriverAgent's developer — tap Trust on the "
                 + "phone, or trust it in Settings ▸ General ▸ VPN & Device Management."
        }
    }

    private func runnerInstall(_ event: RunnerInstallEvent) {
        guard running else { return }
        switch event {
        case .checking:
            break                               // fast; don't flash the status
        case .installing:
            installingRunner = true
            status("Installing WebDriverAgent on \(alias)… (first time can take ~30s)")
        case .upgrading(let from, let to):
            installingRunner = true
            // May raise the passcode sheet; B1b's hold covers it.
            log(.runnerUpgrade, from: from, to: to,
                detail: "reinstalling the runner; the phone may ask for its passcode once")
            status("Updating WebDriverAgent on \(alias) to \(to)… the phone may ask for its "
                 + "passcode to Enable UI Automation.")
        case .upgradeFailed(let kept, let raw):
            log(.runnerUpgrade, from: kept, detail: "upgrade failed, keeping \(kept): \(raw)")
            status("Couldn’t update WebDriverAgent on \(alias); starting the installed one.")
        case .done(let result):
            installingRunner = false
            lastRunnerInstall = result
            switch result {
            case .installed:
                status("WebDriverAgent installed on \(alias) — starting…")
            case .alreadyPresent, .noBundle:
                break                           // normal boot; the probe takes over
            case .failed(let err):
                if case .other(let raw) = err { lastError = String(raw.prefix(200)) }
                setHealth(.down)
                status(Self.installFailureMessage(err, alias: alias))
            }
        case .abandoned:
            // The chain restarted mid-install; the new bring-up checks again.
            installingRunner = false
        }
        onChange?()
    }

    private func status(_ text: String) {
        detail = text
        onStatus?(text)
    }

    /// Actionable, per-cause message for a failed runner install.
    static func installFailureMessage(_ err: RunnerInstallError, alias: String) -> String {
        switch err {
        case .notProvisioned:
            return "Couldn’t install WebDriverAgent on \(alias) — it isn’t signed for this iPhone. "
                 + "Re-sign it for this device, then turn Automation off and on: "
                 + "WDA_DESTINATION=<its-udid> ./scripts/build-wda.sh"
        case .deviceLocked:
            return "Couldn’t install WebDriverAgent on \(alias) — unlock it, then press "
                 + "Restart for it in Settings."
        case .other(let raw):
            return "WebDriverAgent install failed on \(alias): \(raw)"
        }
    }

    /// One line on whether the runner is on this phone, for Settings.
    var runnerText: String {
        if health == .connected { return "WebDriverAgent running ✓" }
        if unrecoverable { return "WebDriverAgent won't start — trust the developer on the phone" }
        if ladder.hardStopped { return "Gave up for now — retries by itself, or press Restart" }
        if installingRunner { return "Installing WebDriverAgent…" }
        switch lastRunnerInstall {
        case .alreadyPresent, .installed: return "WebDriverAgent installed — starting…"
        case .failed(.notProvisioned): return "WebDriverAgent not signed for this iPhone"
        case .failed(.deviceLocked): return "Unlock the iPhone, then Restart"
        case .failed(.other): return "WebDriverAgent install failed"
        case .noBundle, nil: return "Starting WebDriverAgent…"
        }
    }
}
