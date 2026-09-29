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
    private(set) var ladder = ChainLadderState()

    private var probing = false
    private var creatingSession = false
    private var timer: Timer?
    private var running = false

    // Wired by ChainManager.
    /// Is any OTHER phone connected right now? (The tunnel is shared, so
    /// restarting it costs them their WDA.)
    var othersHealthy: () -> Bool = { false }
    /// Does the shared tunnel list a route to this phone (last poll)?
    var tunnelHasDevice: () -> Bool = { true }
    /// Ask for the shared tunnel (and so every chain) to restart.
    var requestTunnelRestart: () -> Void = {}

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
        chain?.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + stagger) { [weak self] in
            guard let self, self.running, self.timer == nil else { return }
            self.probeNow()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.probeNow() }
            RunLoop.main.add(t, forMode: .common)   // keep firing during UI tracking
            self.timer = t
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
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
        ladder.forceRetry(now: ProcessInfo.processInfo.systemUptime)
        unrecoverable = false
        status("Retrying WebDriverAgent on \(alias)…")
        restartOwnOrTunnel()
    }

    /// Settings → Restart: this phone's chain only.
    func restartChain() {
        ladder.forceRetry(now: ProcessInfo.processInfo.systemUptime)
        unrecoverable = false
        status("Restarting \(alias)'s connection…")
        chain?.restart()
        onChange?()
    }

    func bounceMJPEGForward() { chain?.bounceMJPEGForward() }

    /// The window's video watchdog gave up on a bounce: restart this chain.
    func restartForStalledVideo() {
        ladder.noteOutsideRestart()
        status("Video stalled — resetting \(alias)'s connection…")
        chain?.restart()
    }

    /// The window's video watchdog gave up for good.
    func hardStopForStalledVideo() {
        ladder.hardStop()
        chain?.stopChildren()
        status("No video from WebDriverAgent on \(alias). Tap WDA to retry.")
        onChange?()
    }

    /// The shared tunnel was just restarted for everyone: this chain was
    /// rebuilt too, so a give-up here no longer holds.
    func tunnelRestarted() {
        if ladder.hardStopped { ladder.forceRetry(now: ProcessInfo.processInfo.systemUptime) }
    }

    // MARK: Device file

    var registryState: RegisteredDevice.State {
        if ladder.hardStopped || unrecoverable { return .failed }
        if case .failed = lastRunnerInstall { return .failed }
        if installingRunner { return .installing }
        switch health {
        case .connected: return .ready
        case .connecting: return .starting
        case .down: return ladder.hadSuccessfulConnection ? .down : .starting
        }
    }

    // MARK: Health probe + recovery ladder

    private func probeNow() {
        guard running, !installingRunner, !probing else { return }
        // Don't probe mid-gesture: the GET would queue behind the /actions on
        // WDA's single XCUITest queue and could time out into a false .down.
        if wda.isGestureInFlight { return }
        probing = true
        wda.probe { [weak self] result in          // delivered on main
            guard let self else { return }
            self.probing = false
            guard self.running else { return }
            switch result {
            case .alive: self.setHealth(.connected)
            case .down: self.setHealth(.down)
            case .needsSession: self.createSession()
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
        let action = ladder.tick(now: ProcessInfo.processInfo.systemUptime,
                                 othersHealthy: othersHealthy(), tunnelHasDevice: tunnelHasDevice())
        switch action {
        case .wait:
            break
        case .restartDeviceChain:
            // Don't reseed the clock here: onRunwdaStarted does once the new
            // runwda spawns, and a chain that never gets that far still ages
            // toward the next stage instead of sitting on .wait forever.
            status("WebDriverAgent on \(alias) is taking longer than usual — restarting its connection…")
            chain?.restart()
        case .restartTunnelAndChains:
            status("WebDriverAgent on \(alias) is taking longer than usual — resetting the USB connection…")
            requestTunnelRestart()
        case .giveUp:
            // Stop the children outright, or runwda keeps respawning (and being
            // killed by its readiness deadline) forever after a give-up. The
            // relay stays up, so a retry can bring the chain back.
            chain?.stopChildren()
            status("WebDriverAgent won't start on \(alias). Tap WDA to retry.")
            onChange?()
        }
    }

    private func restartOwnOrTunnel() {
        if tunnelHasDevice() { chain?.restart() } else { requestTunnelRestart() }
        onChange?()
    }

    private func runnerInstall(_ event: RunnerInstallEvent) {
        guard running else { return }
        switch event {
        case .checking:
            break                               // fast; don't flash the status
        case .installing:
            installingRunner = true
            status("Installing WebDriverAgent on \(alias)… (first time can take ~30s)")
        case .done(let result):
            installingRunner = false
            lastRunnerInstall = result
            switch result {
            case .installed:
                status("WebDriverAgent installed on \(alias) — starting…")
            case .alreadyPresent, .noBundle:
                break                           // normal boot; the probe takes over
            case .failed(let err):
                setHealth(.down)
                status(Self.installFailureMessage(err, alias: alias))
            }
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
        if ladder.hardStopped { return "Gave up — press Restart" }
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
