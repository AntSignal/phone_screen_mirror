// DeviceTransport — the go-ios control channel, one chain per phone.
//
// One userspace tunnel serves every phone on the Mac; each phone then gets its
// own runwda and forwards (always with --udid, so go-ios never falls back to
// "first device in list") and its own in-process relay, on its port slot:
//
//   ios tunnel start --userspace              shared: TunnelSupervisor
//   ios runwda  --udid=U                      per phone: DeviceChain
//   ios forward --udid=U <slot.forward> 8100  WDA
//   ios forward --udid=U <slot.mjpeg>   9100  MJPEG mirror
//   LocalRelay <slot.relay> -> <slot.forward> CFNetwork-friendly loopback pump
//
// Slot 0 is exactly the single-phone layout (8100 / 8101 / 9110).
//
// SECURITY: relays bind 127.0.0.1 only. WDA has no auth on the wire.

import Foundation
import iMirrorCore

// MARK: - go-ios command lines

enum GoIOS {
    /// go-ios's tunnel agent (serves /tunnels), shared by every phone.
    static let tunnelAgentPort = 60105

    static let tunnelArgs = ["tunnel", "start", "--userspace"]
    static let listArgs = ["list", "--details"]

    // --udid goes right after the subcommand (verified against the pinned
    // go-ios) so the sweep pattern below can anchor on it.
    static func runwdaArgs(udid: String) -> [String] {
        ["runwda", "--udid=\(udid)",
         "--bundleid=\(WDAIdentity.runnerBundleId)",
         "--testrunnerbundleid=\(WDAIdentity.testRunnerBundleId)",
         "--xctestconfig=\(WDAIdentity.xctestConfig)"]
    }

    static func forwardArgs(udid: String, hostPort: UInt16, devicePort: UInt16) -> [String] {
        ["forward", "--udid=\(udid)", String(hostPort), String(devicePort)]
    }

    static func appsListArgs(udid: String) -> [String] { ["apps", "--list", "--udid=\(udid)"] }

    static func installArgs(udid: String, ipa: String) -> [String] {
        ["install", "--udid=\(udid)", "--path=\(ipa)"]
    }

    /// `pkill -f` pattern for one phone's runwda/forwards, and nothing else —
    /// in particular not another phone's chain, which a bare "<bin> runwda"
    /// sweep (the single-phone design) would kill too.
    static func sweepPattern(bin: String, udid: String) -> String {
        "^\(ereEscape(bin)) (runwda|forward) --udid=\(ereEscape(udid))( |$)"
    }

    /// Every go-ios child started from `bin`, udid or not. Only for app start /
    /// Automation on, before this app owns any child: it clears orphans a
    /// crashed instance left (often a tunnel still holding :60105).
    static func sweepAllPatterns(bin: String) -> [String] {
        ["tunnel", "runwda", "forward"].map { "^\(ereEscape(bin)) \($0)( |$)" }
    }

    static func tunnelSweepPattern(bin: String) -> String { "^\(ereEscape(bin)) tunnel( |$)" }

    static func pkill(_ pattern: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() }
        catch { NSLog("iMirror: pkill \(pattern) failed: \(error.localizedDescription)") }
    }

    /// Run go-ios to completion. Blocking: call off the main thread.
    static func run(_ bin: URL, _ args: [String], workDir: URL) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = workDir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            // Drain both pipes before waiting so a full buffer can't deadlock.
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            p.waitUntilExit()
            return (p.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
    }

    private static func ereEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.[]|()*+?{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// Blocking GET of a loopback URL with a short timeout. Call off the main thread.
func loopbackGET(_ url: URL, session: URLSession, timeout: TimeInterval) -> (Int?, Data?) {
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let sem = DispatchSemaphore(value: 0)
    var result: (Int?, Data?) = (nil, nil)
    session.dataTask(with: req) { data, resp, _ in
        result = ((resp as? HTTPURLResponse)?.statusCode, data)
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.5)
    return result
}

// MARK: - The shared tunnel

/// The Mac's single `ios tunnel start --userspace`. Every phone's chain rides
/// it, so restarting it drops WDA on all of them — ChainManager decides when.
final class TunnelSupervisor {
    private let bin: URL
    private let workDir: URL
    private var tunnel: ManagedProcess?
    /// Any queue, after each tunnel spawn: every phone's USB resets.
    var onSpawn: (() -> Void)?
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    init(bin: URL, workDir: URL) {
        self.bin = bin
        self.workDir = workDir
    }

    func start() {
        guard tunnel == nil else { return }
        let t = ManagedProcess(binary: bin, args: GoIOS.tunnelArgs, label: "tunnel",
                               restartDelay: 15, workDir: workDir)
        t.onSpawn = onSpawn
        tunnel = t
        t.start()
    }

    func stop() {
        tunnel?.stop()
        tunnel = nil
    }

    /// Phones with an established tunnel right now. Blocking: off main.
    /// (The agent's /ready answers before any device tunnel exists, so only a
    /// phone listed in /tunnels counts.)
    func tunneledUDIDs() -> Set<String> {
        guard let url = URL(string: "http://127.0.0.1:\(GoIOS.tunnelAgentPort)/tunnels") else { return [] }
        let (code, data) = loopbackGET(url, session: session, timeout: 1.5)
        guard let code, (200..<300).contains(code), let data else { return [] }
        return GoIOSParsing.tunnelUDIDs(fromTunnels: data)
    }

    /// Tear the tunnel down, clear any orphan still holding :60105, start again.
    /// `completion` runs on main once the new tunnel process is spawned.
    func restart(completion: @escaping () -> Void) {
        stop()
        let bin = self.bin
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            GoIOS.pkill(GoIOS.tunnelSweepPattern(bin: bin.path))
            DispatchQueue.main.async {
                self?.start()
                completion()
            }
        }
    }
}

// MARK: - One phone's chain

/// runwda + the WDA and MJPEG forwards + the loopback relay for one phone.
/// Restarting it touches nothing else: not the tunnel, not the other phones.
final class DeviceChain {
    let udid: String
    let slot: PortSlot
    private let bin: URL
    private let workDir: URL
    /// Runs bring-ups and the restart sweep. Tests pass a queue they can
    /// suspend, to land a stop between a step and its callback.
    private let startupQueue: DispatchQueue
    private let relay: LocalRelay
    private var wda: ManagedProcess?
    private var forward: ManagedProcess?
    private var mjpegForward: ManagedProcess?
    private var relayUp = false
    /// Goes up each time the chain starts (devices.json chain_epoch), so a
    /// client can tell "same WDA, slow" from "rebuilt under me".
    private(set) var epoch = 0
    // Read by runwda's queues as well as main.
    private let holdLock = NSLock()
    private var hold = PasscodeHold()

    private let readinessSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Asked (off main) whether the shared tunnel has a route to this phone yet.
    var tunnelHasDevice: () -> Bool = { true }
    /// Main thread. The runner can't start at all (signing / trust).
    var onWDAUnrecoverable: (() -> Void)?
    /// Main thread. Runner check/install progress for the UI.
    var onRunnerInstall: ((RunnerInstallEvent) -> Void)?
    /// Main thread, once per bring-up: runwda has just been spawned — the point
    /// the recovery ladder's boot grace starts counting from.
    var onRunwdaStarted: (() -> Void)?
    /// Main thread. We started or stopped this phone's runner, which resets
    /// its USB; that reset is ours, not a fault (USBResetWatch).
    var onOwnUSBChange: (() -> Void)?
    /// Main thread. runwda's output named a cause a person must fix, and/or
    /// go-ios logged an error (short, for last_error).
    var onRunwdaLog: ((RunwdaLogClass?, String?) -> Void)?

    /// Is runwda waiting on the passcode sheet, within its cap? Any queue.
    var passcodeHeld: Bool {
        holdLock.lock(); defer { holdLock.unlock() }
        return hold.holding(now: ProcessInfo.processInfo.systemUptime)
    }

    /// WDA answered, or a person asked for a retry: stop holding.
    func clearPasscodeHold() {
        holdLock.lock(); hold.clear(); holdLock.unlock()
    }

    /// Any queue: classify a batch of runwda lines.
    private func runwdaSaid(_ lines: [String]) {
        var cls: RunwdaLogClass?, err: String?
        for line in lines {
            if let c = classifyRunwdaLine(line) { cls = c }
            if let e = runwdaErrorSummary(line) { err = e }
        }
        guard cls != nil || err != nil else { return }
        if cls == .needsPasscode {
            holdLock.lock(); hold.sheetSeen(now: ProcessInfo.processInfo.systemUptime); holdLock.unlock()
        }
        DispatchQueue.main.async { [weak self] in self?.onRunwdaLog?(cls, err) }
    }

    // Bumped by every start/stop/restart; a delayed bring-up step aborts if it
    // moved, so a stop landing mid-bring-up can't spawn orphans afterwards.
    private let genLock = NSLock()
    private var _generation = 0
    private var generation: Int {
        get { genLock.lock(); defer { genLock.unlock() }; return _generation }
        set { genLock.lock(); _generation = newValue; genLock.unlock() }
    }

    /// Short, filesystem-safe tag for log files and process labels.
    private var tag: String { String(udid.replacingOccurrences(of: "-", with: "").suffix(6)) }

    init(udid: String, slot: PortSlot, bin: URL, workDir: URL,
         startupQueue: DispatchQueue = .global(qos: .userInitiated)) {
        self.udid = udid
        self.slot = slot
        self.bin = bin
        self.workDir = workDir
        self.startupQueue = startupQueue
        self.relay = LocalRelay(listen: slot.relayPort, backend: slot.forwardPort)
    }

    /// Introspection for lifecycle tests: does any child handle exist?
    var hasChildHandlesForTesting: Bool { wda != nil || forward != nil || mjpegForward != nil }

    /// Main thread. A new generation makes every queued callback of the
    /// old one stale; an install the UI saw start is reported abandoned.
    private func newGeneration() {
        generation += 1
        if installGate.superseded() { onRunnerInstall?(.abandoned) }
    }

    /// Run `body` on main only if the chain is still at generation `gen`.
    /// A stop or restart between the event and its delivery drops it.
    private func onMainIfCurrent(_ gen: Int, _ body: @escaping (DeviceChain) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            body(self)
        }
    }

    /// Start the relay (once — it stays up across chain restarts so the
    /// readiness probe path keeps working) and bring the chain up.
    func start() {
        if !relayUp {
            do { try relay.start(); relayUp = true }
            catch { NSLog("iMirror: relay :\(slot.relayPort) failed: \(error.localizedDescription)") }
        }
        newGeneration()
        epoch += 1
        onOwnUSBChange?()
        bringUp(generation: generation)
    }

    /// Stop the children and the relay. The phone is going away.
    func stop() {
        stopChildren()
        relay.stop()
        relayUp = false
    }

    /// Stop the children but keep the relay listening (the give-up state).
    func stopChildren() {
        newGeneration()
        onOwnUSBChange?()
        forward?.stop(); mjpegForward?.stop(); wda?.stop()
        forward = nil; mjpegForward = nil; wda = nil
    }

    /// Restart this phone's children only: settle, sweep this phone's
    /// orphans, bring it back. The tunnel and every other phone stay up.
    func restart() {
        NSLog("iMirror: restarting chain for \(udid)")
        stopChildren()
        epoch += 1
        let gen = generation
        let pattern = GoIOS.sweepPattern(bin: bin.path, udid: udid)
        startupQueue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == gen else { return }
            GoIOS.pkill(pattern)
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                self.bringUp(generation: gen)
            }
        }
    }

    func bounceMJPEGForward() { mjpegForward?.bounce() }

    /// Requests waiting on this phone's WDA through its relay.
    var relayInFlight: Int { relay.inFlight }
    var relayRequestsSeen: Int { relay.requestsSeen }
    /// Readiness checks sent through the relay; they are not client traffic.
    var readinessRequestsSent: Int { holdLock.lock(); defer { holdLock.unlock() }; return readinessSent }
    private var readinessSent = 0

    /// Tunnel route → runner check/install → runwda + forwards. The install and
    /// `apps --list` go through the tunnel on iOS 17+, so they must wait for it.
    private func bringUp(generation gen: Int) {
        startupQueue.async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if self.generation != gen { return }
                if self.tunnelHasDevice() { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard self.generation == gen else { return }
            let install = self.installOrUpgradeRunner(generation: gen)
            guard self.generation == gen, shouldSpawnRunwda(after: install) else { return }
            self.onMainIfCurrent(gen) { $0.spawnChildren(generation: gen) }
        }
    }

    private func spawnChildren(generation gen: Int) {
        let wda = ManagedProcess(
            binary: bin, args: GoIOS.runwdaArgs(udid: udid), label: "runwda-\(tag)",
            restartDelay: 6, workDir: workDir,
            // A wedged runwda never exits, so give it a readiness deadline,
            // checked through this phone's own relay (CFNetwork is unreliable
            // against a raw go-ios forward port). 40s is past WDA's ~20s boot.
            readinessCheck: { [weak self] in self?.wdaReadyThroughRelay() ?? false },
            readyWithin: 40, readinessPollInterval: 2)
        wda.holdCheck = { [weak self] in self?.passcodeHeld ?? false }
        wda.onLines = { [weak self] lines in self?.runwdaSaid(lines) }
        // A runner this chain has since replaced must not mark the new one
        // "won't start" (upstream fed3fb9).
        wda.onGaveUp = { [weak self] _ in
            self?.onMainIfCurrent(gen) { $0.onWDAUnrecoverable?() }
        }
        // Respawns too: each runner start resets the phone's USB.
        wda.onSpawn = { [weak self] in
            DispatchQueue.main.async { self?.onOwnUSBChange?() }
        }
        self.wda = wda
        wda.start()
        onRunwdaStarted?()
        forward = ManagedProcess(
            binary: bin, args: GoIOS.forwardArgs(udid: udid, hostPort: slot.forwardPort, devicePort: 8100),
            label: "forward-\(tag)", restartDelay: 3, workDir: workDir)
        forward?.start()
        mjpegForward = ManagedProcess(
            binary: bin, args: GoIOS.forwardArgs(udid: udid, hostPort: slot.mjpegPort, devicePort: 9100),
            label: "mjpeg-forward-\(tag)", restartDelay: 3, workDir: workDir)
        mjpegForward?.start()
    }

    private func wdaReadyThroughRelay() -> Bool {
        guard let url = URL(string: "\(slot.relayURL)/status") else { return false }
        holdLock.lock(); readinessSent += 1; holdLock.unlock()
        let (code, data) = loopbackGET(url, session: readinessSession, timeout: 2)
        guard let code, (200..<300).contains(code), let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return WDAParse.ready(json)
    }

    // MARK: Runner check / install

    // Main thread only.
    private var installGate = InstallEventGate()

    /// Any queue. Events from a replaced bring-up are dropped (InstallEventGate).
    private func emitInstall(_ event: RunnerInstallEvent, generation gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.installGate.pass(event, from: gen, current: self.generation) else { return }
            self.onRunnerInstall?(event)
        }
    }

    /// A bundled version whose upgrade failed on this chain (runnerAction).
    /// Bring-ups run off main and may overlap, so it sits behind holdLock.
    private var _failedUpgradeTo: String?
    private var failedUpgradeTo: String? {
        get { holdLock.lock(); defer { holdLock.unlock() }; return _failedUpgradeTo }
        set { holdLock.lock(); _failedUpgradeTo = newValue; holdLock.unlock() }
    }

    /// Check the branded runner on THIS phone. Install the bundled ipa when
    /// it is missing, and reinstall it when the phone's copy is older. Dev
    /// builds ship no ipa (scripts/build-wda.sh installs the runner), which
    /// is reported as `.noBundle`.
    private func installOrUpgradeRunner(generation gen: Int) -> RunnerInstall {
        let emit = { (e: RunnerInstallEvent) in self.emitInstall(e, generation: gen) }
        emit(.checking)
        guard let ipa = Bundle.main.url(forResource: "WebDriverAgent", withExtension: "ipa") else {
            emit(.done(.noBundle))
            return .noBundle
        }
        let installed = installedRunnerVersion()
        let bundled = Self.bundledRunnerVersion(ipa: ipa)
        switch runnerAction(installed: installed, bundled: bundled, failedUpgradeTo: failedUpgradeTo) {
        case .keep:
            emit(.done(.alreadyPresent))
            return .alreadyPresent
        case .install:
            emit(.installing)
            let result = installWithRetry(ipa: ipa)
            emit(.done(result))
            return result
        case .upgrade:
            let from = installed ?? "", to = bundled ?? ""
            emit(.upgrading(from: from, to: to))
            let attempt = installWithRetry(ipa: ipa)
            if case .failed(let err) = attempt {
                failedUpgradeTo = to
                emit(.upgradeFailed(kept: from, raw: err.raw))
            }
            let result = upgradeResult(attempt)
            emit(.done(result))
            return result
        }
    }

    /// `ios install` with retries: `.installed` or the last `.failed`.
    private func installWithRetry(ipa: URL) -> RunnerInstall {
        // The tunnel is briefly unusable right after it appears; retry the
        // unrecognised (transient) failures, stop at once on a definite one
        // (not provisioned for this phone, phone locked).
        var result: RunnerInstall = .failed(.other(raw: "install did not run"))
        for attempt in 0..<8 {
            let r = GoIOS.run(bin, GoIOS.installArgs(udid: udid, ipa: ipa.path), workDir: workDir)
            if r.status == 0 { result = .installed; break }
            let cls = classifyInstallError(r.err)
            result = .failed(cls)
            if case .other = cls, attempt < 7 { Thread.sleep(forTimeInterval: 2); continue }
            break
        }
        return result
    }

    /// The phone's runner version: nil when it is not installed or the
    /// listing failed (then we install, as before), "" when it has none.
    private func installedRunnerVersion() -> String? {
        let r = GoIOS.run(bin, GoIOS.appsListArgs(udid: udid), workDir: workDir)
        guard r.status == 0 else { return nil }
        return runnerVersion(inAppsList: String(decoding: r.out, as: UTF8.self),
                             bundleId: WDAIdentity.runnerBundleId)
    }

    // The ipa cannot change while the app runs, so read it once.
    private static let bundledVersionLock = NSLock()
    private static var bundledVersionCache: String?

    /// CFBundleShortVersionString of the runner in the bundled ipa, which
    /// build-wda.sh stamps with the WDA release. nil if unreadable.
    private static func bundledRunnerVersion(ipa: URL) -> String? {
        bundledVersionLock.lock(); defer { bundledVersionLock.unlock() }
        if let v = bundledVersionCache { return v }
        let r = GoIOS.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                          ["-p", ipa.path, "Payload/*.app/Info.plist"],
                          workDir: FileManager.default.temporaryDirectory)
        guard r.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: r.out, format: nil) as? [String: Any],
              let v = plist["CFBundleShortVersionString"] as? String else { return nil }
        bundledVersionCache = v
        return v
    }
}
