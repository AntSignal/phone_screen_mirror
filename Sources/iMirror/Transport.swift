// Transport — the building blocks of iMirror's self-managed USB control channel.
//
// The app spawns everything needed for headless control (no Xcode, no sudo).
// DeviceTransport.swift assembles these pieces into one chain per phone:
//
//   ios tunnel start --userspace   RSD tunnel for iOS 17+ (userspace = no root)
//   ios runwda --udid=U            launches WebDriverAgent on that phone
//   ios forward --udid=U P 8100    USB relay of WDA's port to localhost:P
//   LocalRelay R -> P              in-process loopback pump (CFNetwork-friendly)
//
//   iMirror (CFNetwork) -> 127.0.0.1:R (relay) -> :P (forward) --USB--> WDA
//
// Each child is auto-restarted if it dies, so the channel self-heals (a wedged
// WDA — the recurring failure under Xcode — just respawns). All children are
// terminated when the app quits.
//
// SECURITY: the relay binds 127.0.0.1 only. WDA has no auth on the wire, so it is
// never exposed beyond loopback.

import Foundation
import Network
import iMirrorCore

// MARK: - Branded WDA runner identity
//
// The runner is rebranded to iMirror at build time (see scripts/build-wda.sh).
// Xcode appends ".xctrunner" to the UI-test target's bundle id when it wraps it
// into the runner .app, so go-ios is told the *suffixed* id. PRODUCT_NAME stays
// WebDriverAgentRunner, so xctestConfig keeps the default name — but go-ios still
// requires it explicitly whenever bundleid/testrunnerbundleid are set.
enum WDAIdentity {
    static let runnerBundleId = "com.local.imirror.WebDriverAgentRunner.xctrunner"
    static let testRunnerBundleId = "com.local.imirror.WebDriverAgentRunner.xctrunner"
    static let xctestConfig = "WebDriverAgentRunner.xctest"
}

// MARK: - Locate the bundled go-ios binary

func locateGoIOS() -> URL? {
    if let bundled = Bundle.main.url(forResource: "ios", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }
    if let env = ProcessInfo.processInfo.environment["IMIRROR_IOS_BIN"],
       FileManager.default.isExecutableFile(atPath: env) {
        return URL(fileURLWithPath: env)
    }
    // Dev fallback: <repo>/ios-mirror/tools/go-ios/bin/ios relative to this source.
    let dev = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/go-ios/bin/ios")
    return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
}

// MARK: - A child process that respawns if it exits

final class ManagedProcess {
    private let binary: URL
    private let args: [String]
    private let label: String
    private let restartDelay: TimeInterval
    private let workDir: URL
    private var process: Process?
    private var stopped = false
    // `stopped`/`process`/`generation`/`readySeen`/`killedUnready` are touched
    // from the caller's thread, the spawn-delay queue, the readiness-poll queue,
    // AND Process.terminationHandler's private queue — guard every access.
    private let lock = NSLock()

    // Circuit breaker: a child that can never start (bad signing, unsupported
    // iOS) would otherwise crash-loop at `restartDelay` forever. Count quick
    // deaths; back off exponentially, and after `maxQuickFailures` give up so the
    // app's slower chain-level watchdog takes over instead of a tight spin.
    // Monotonic (systemUptime, never Date()) and read/written only inside
    // `lock`, matching the readiness-poll code, so `ranFor` below can't tear
    // or get skewed by a Mac sleep between spawn and exit.
    private var spawnedAt: TimeInterval?
    private var consecutiveFailures = 0
    private let maxQuickFailures = 8
    // A child that stayed up at least this long was healthy — a later exit is a
    // normal drop (device asleep, WDA recycled), not a failed launch, so the
    // failure streak resets rather than marching toward the give-up cap.
    private let healthyRuntimeSec: TimeInterval = 20
    /// Called (once, on a background queue) when the breaker trips. Lets the
    /// Transport surface a terminal "this device/OS may not support WDA" state
    /// instead of the channel silently looping on red.
    var onGaveUp: ((String) -> Void)?

    // Readiness deadline: a wedged `runwda` never exits, so the exit-triggered
    // respawn above never fires for it. If a readiness check is supplied, poll it
    // after spawn and SIGKILL the child if it never reports ready within
    // `readyWithin`, so the existing termination handler respawns it anyway.
    private let readinessCheck: (() -> Bool)?
    private let readyWithin: TimeInterval
    // Production cadence is 2s so an idle readiness check (typically an HTTP
    // probe) doesn't spin. Tests inject a much shorter interval to exercise the
    // deadline without a multi-second sleep per case.
    private let readinessPollInterval: TimeInterval
    // Bumped on every spawn so a readiness poll from a previous spawn can never
    // act on (or kill) a newer process.
    private var generation = 0
    private var readySeen = false
    // Set right before a readiness-deadline kill and consumed by the termination
    // handler for that same spawn, so the failure counter can tell a wedge apart
    // from a normal exit — see the termination handler below.
    private var killedUnready = false

    init(binary: URL, args: [String], label: String, restartDelay: TimeInterval, workDir: URL,
         readinessCheck: (() -> Bool)? = nil, readyWithin: TimeInterval = 0,
         readinessPollInterval: TimeInterval = 2) {
        self.binary = binary
        self.args = args
        self.label = label
        self.restartDelay = restartDelay
        self.workDir = workDir
        self.readinessCheck = readinessCheck
        self.readyWithin = readyWithin
        self.readinessPollInterval = readinessPollInterval
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// The pid of the currently running spawn, if any. Test-only introspection.
    var currentPidForTesting: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true ? process?.processIdentifier : nil
    }

    func start() {
        lock.lock()
        stopped = false
        consecutiveFailures = 0
        killedUnready = false
        lock.unlock()
        spawn()
    }

    func stop() {
        lock.lock()
        stopped = true
        let p = process
        process = nil
        lock.unlock()
        p?.terminationHandler = nil
        p?.terminate()
        // terminate() only sends SIGTERM; a wedged child that ignores it would
        // otherwise linger (and, on quit, reparent to launchd). Escalate to
        // SIGKILL shortly after if it hasn't exited — off the caller's thread so
        // neither app-quit nor a chain restart blocks waiting on it.
        if let p {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Kill the current instance so the termination handler respawns it. Used by
    /// the watchdog to recover a hung child (one that never exits on its own).
    func bounce() {
        NSLog("iMirror: bouncing \(label)")
        lock.lock(); let p = process; lock.unlock()
        p?.terminate()
        // terminate() only sends SIGTERM; a wedged child ignores it and would
        // never actually bounce. Escalate to SIGKILL shortly after if it's still
        // running, off the caller's thread, same pattern as stop().
        if let p {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Poll `readinessCheck` for the spawn identified by `myGeneration`, killing
    /// its process if it never reports ready within `readyWithin`. Stops on its
    /// own once ready, once a newer spawn replaces this one, or once stopped.
    private func scheduleReadinessPoll(process p: Process, generation myGeneration: Int,
                                       start: TimeInterval, check: @escaping () -> Bool) {
        DispatchQueue.global().asyncAfter(deadline: .now() + readinessPollInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == myGeneration && !self.stopped
            self.lock.unlock()
            guard stillCurrent else { return }

            if check() {
                self.lock.lock()
                if self.generation == myGeneration { self.readySeen = true }
                self.lock.unlock()
                return   // ready — poll is done
            }

            // Monotonic clock: ProcessInfo.systemUptime, never Date(), so a Mac
            // sleep between polls can't skew the elapsed time and trigger a
            // spurious kill right after wake.
            let uptime = ProcessInfo.processInfo.systemUptime - start
            self.lock.lock()
            let shouldKill = self.generation == myGeneration && !self.stopped
                && managedProcessShouldKillForUnreadiness(uptime: uptime, readySeen: self.readySeen, readyWithin: self.readyWithin)
            if shouldKill { self.killedUnready = true }
            self.lock.unlock()

            if shouldKill {
                NSLog("iMirror: \(self.label) not ready within \(Int(self.readyWithin))s — killing")
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                return
            }
            self.scheduleReadinessPoll(process: p, generation: myGeneration, start: start, check: check)
        }
    }

    private func spawn() {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        // go-ios writes selfIdentity.plist + pair records into its cwd; the app's
        // default cwd is "/" (read-only), so point it at a writable dir.
        p.currentDirectoryURL = workDir
        // Child output is discarded by default. Set IMIRROR_DEBUG=1 to capture it
        // to <workDir>/<label>.log (truncated per spawn, so it stays bounded).
        if ProcessInfo.processInfo.environment["IMIRROR_DEBUG"] != nil {
            let logURL = workDir.appendingPathComponent("\(label).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logURL) {
                p.standardOutput = fh
                p.standardError = fh
            }
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); return }
            // F8: read alongside the other spawn-generation state, under the
            // same lock, instead of racing the wall clock outside it.
            let ranFor = self.spawnedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            let wasKilledUnready = self.killedUnready
            self.killedUnready = false
            if wasKilledUnready {
                // A readiness-deadline kill is a failed launch no matter how long
                // the wedged process happened to sit there — it never actually
                // served WDA, so it must NOT reset the streak like a healthy exit
                // would, or a permanent wedge would never trip the give-up breaker.
                self.consecutiveFailures += 1
            } else if ranFor >= self.healthyRuntimeSec {
                self.consecutiveFailures = 0        // was healthy; this is a normal drop
            } else {
                self.consecutiveFailures += 1       // died fast; likely a failed launch
            }
            let failures = self.consecutiveFailures
            self.lock.unlock()
            // Exponential backoff capped at 60s so an unrecoverable child (bad
            // signing, unsupported iOS, or just an unplugged phone) can't spin at
            // the base delay (runwda: 6s) for the whole app lifetime. We keep
            // retrying at the cap — a later replug still recovers on its own —
            // but fire onGaveUp exactly once when we cross the threshold so the
            // app can surface a terminal-looking state instead of silent looping.
            let delay = min(self.restartDelay * pow(2.0, Double(max(0, failures - 1))), 60)
            if failures == self.maxQuickFailures {
                NSLog("iMirror: \(self.label) failed \(failures)x — backing off to "
                      + "\(Int(delay))s (device/OS may not support WDA, or phone is unplugged)")
                self.onGaveUp?(self.label)
            } else {
                NSLog("iMirror: \(self.label) exited — restarting in \(Int(delay))s (fail \(failures))")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.spawn()
            }
        }
        do {
            try p.run()
            lock.lock()
            if stopped {
                // stop() landed between p.run() succeeding and this lock —
                // no handle was ever assigned for this spawn, so stop()'s
                // own terminate()/SIGKILL never reached it. Tear it down
                // ourselves here instead of leaving it running, orphaned.
                lock.unlock()
                p.terminationHandler = nil
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
                return
            }
            process = p
            spawnedAt = ProcessInfo.processInfo.systemUptime
            generation += 1
            let myGeneration = generation
            readySeen = false
            lock.unlock()
            NSLog("iMirror: started \(label) (pid \(p.processIdentifier))")
            if let readinessCheck, readyWithin > 0 {
                scheduleReadinessPoll(process: p, generation: myGeneration,
                                      start: ProcessInfo.processInfo.systemUptime, check: readinessCheck)
            }
        } catch {
            NSLog("iMirror: failed to start \(label): \(error.localizedDescription)")
        }
    }
}

// MARK: - In-process loopback TCP relay

final class LocalRelay {
    private let listenPort: UInt16
    private let backendPort: UInt16
    private let queue = DispatchQueue(label: "imirror.relay")
    private var listener: NWListener?

    init(listen: UInt16 = 8100, backend: UInt16 = 8101) {
        self.listenPort = listen
        self.backendPort = backend
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                  port: NWEndpoint.Port(rawValue: listenPort)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
        NSLog("iMirror: relay 127.0.0.1:\(listenPort) -> 127.0.0.1:\(backendPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ client: NWConnection) {
        let backend = NWConnection(host: "127.0.0.1",
                                   port: NWEndpoint.Port(rawValue: backendPort)!,
                                   using: .tcp)
        client.start(queue: queue)
        backend.start(queue: queue)
        pump(client, backend)
        pump(backend, client)
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                from.cancel(); to.cancel()
                return
            }
            self.pump(from, to)
        }
    }
}
