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
    private let relay: LocalRelay
    private var wda: ManagedProcess?
    private var forward: ManagedProcess?
    private var mjpegForward: ManagedProcess?
    private var relayUp = false

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

    init(udid: String, slot: PortSlot, bin: URL, workDir: URL) {
        self.udid = udid
        self.slot = slot
        self.bin = bin
        self.workDir = workDir
        self.relay = LocalRelay(listen: slot.relayPort, backend: slot.forwardPort)
    }

    /// Start the relay (once — it stays up across chain restarts so the
    /// readiness probe path keeps working) and bring the chain up.
    func start() {
        if !relayUp {
            do { try relay.start(); relayUp = true }
            catch { NSLog("iMirror: relay :\(slot.relayPort) failed: \(error.localizedDescription)") }
        }
        generation += 1
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
        generation += 1
        forward?.stop(); mjpegForward?.stop(); wda?.stop()
        forward = nil; mjpegForward = nil; wda = nil
    }

    /// Restart this phone's children only: settle, sweep this phone's
    /// orphans, bring it back. The tunnel and every other phone stay up.
    func restart() {
        NSLog("iMirror: restarting chain for \(udid)")
        stopChildren()
        let gen = generation
        let pattern = GoIOS.sweepPattern(bin: bin.path, udid: udid)
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == gen else { return }
            GoIOS.pkill(pattern)
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                self.bringUp(generation: gen)
            }
        }
    }

    func bounceMJPEGForward() { mjpegForward?.bounce() }

    /// Tunnel route → runner check/install → runwda + forwards. The install and
    /// `apps --list` go through the tunnel on iOS 17+, so they must wait for it.
    private func bringUp(generation gen: Int) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if self.generation != gen { return }
                if self.tunnelHasDevice() { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard self.generation == gen else { return }
            let install = self.installRunnerIfMissing()
            guard self.generation == gen, shouldSpawnRunwda(after: install) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.spawnChildren()
            }
        }
    }

    private func spawnChildren() {
        let wda = ManagedProcess(
            binary: bin, args: GoIOS.runwdaArgs(udid: udid), label: "runwda-\(tag)",
            restartDelay: 6, workDir: workDir,
            // A wedged runwda never exits, so give it a readiness deadline,
            // checked through this phone's own relay (CFNetwork is unreliable
            // against a raw go-ios forward port). 40s is past WDA's ~20s boot.
            readinessCheck: { [weak self] in self?.wdaReadyThroughRelay() ?? false },
            readyWithin: 40, readinessPollInterval: 2)
        wda.onGaveUp = { [weak self] _ in
            DispatchQueue.main.async { self?.onWDAUnrecoverable?() }
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
        let (code, data) = loopbackGET(url, session: readinessSession, timeout: 2)
        guard let code, (200..<300).contains(code), let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return WDAParse.ready(json)
    }

    // MARK: Runner check / install

    private func emitInstall(_ event: RunnerInstallEvent) {
        DispatchQueue.main.async { [weak self] in self?.onRunnerInstall?(event) }
    }

    /// Check for the branded runner on THIS phone and install the bundled ipa
    /// if it's missing. Dev builds ship no ipa (the runner is installed by
    /// scripts/build-wda.sh), which is reported as `.noBundle`.
    private func installRunnerIfMissing() -> RunnerInstall {
        emitInstall(.checking)
        guard let ipa = Bundle.main.url(forResource: "WebDriverAgent", withExtension: "ipa") else {
            emitInstall(.done(.noBundle))
            return .noBundle
        }
        if runnerIsInstalled() {
            emitInstall(.done(.alreadyPresent))
            return .alreadyPresent
        }
        emitInstall(.installing)
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
        emitInstall(.done(result))
        return result
    }

    private func runnerIsInstalled() -> Bool {
        let r = GoIOS.run(bin, GoIOS.appsListArgs(udid: udid), workDir: workDir)
        return String(decoding: r.out, as: UTF8.self).contains("com.local.imirror.WebDriverAgentRunner")
    }
}
