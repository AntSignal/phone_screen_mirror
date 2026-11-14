// Boots one iOS Simulator and brings up WebDriverAgent on it, on that sim's own
// loopback ports (SimSlot: :8201/:9201, :8202/:9202, …), so the MCP server can
// drive it. SimulatorManager runs one of these per enabled sim. The WDA build is
// delegated to scripts/sim-wda-up.sh and supervised with ManagedProcess. The
// script comes from the repo checkout (dev) or a copy of the app's bundled
// tools/+scripts/ staged into Application Support (packaged). Viewing is via
// Apple's Simulator app — this type manages lifecycle + status only.

import Foundation
import iMirrorCore

final class SimulatorController {
    let udid: String
    let slot: SimSlot
    /// Reported on the main thread.
    var onPhase: ((SimPhase) -> Void)?

    /// Guarded by `wdaLock`: app quit reads it from the main thread.
    private var wda: ManagedProcess?
    private var quitting = false
    private let wdaLock = NSLock()
    private let queue: DispatchQueue
    /// Bumped by every enable/disable so a poll loop from an earlier enable
    /// stops instead of running beside the new one. Touched on `queue` only.
    private var generation = 0
    private var everReady = false
    private var lastAnswered: TimeInterval = 0
    private var lastBounce: TimeInterval = 0
    private var lastPhase: SimPhase?
    private let workDir: URL

    /// After being ready, this long without /status answering while the runner
    /// process is still alive means it's wedged: bounce it.
    private let wedgedAfter: TimeInterval = 90
    /// …but not again within this long: the relaunch rebuilds first (~30 s).
    private let bounceCooldown: TimeInterval = 240

    init(udid: String, slot: SimSlot) {
        self.udid = udid
        self.slot = slot
        queue = DispatchQueue(label: "com.imirror.sim.\(slot.index)", qos: .userInitiated)
        // Per sim: the IMIRROR_DEBUG log and the WDA build — two builds can't
        // share one derived-data dir.
        workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror/sim/\(udid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    // MARK: Discovery (shared by every controller)

    /// True when full Xcode (not just Command Line Tools) is present — needed to
    /// build/launch the XCUITest runner. Gates the whole feature.
    static func xcodeAvailable() -> Bool {
        run("/usr/bin/xcrun", ["xcodebuild", "-version"]).code == 0
    }

    static func listSimulators() -> [SimDevice] {
        let r = run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"])
        guard r.code == 0, let data = r.out.data(using: .utf8) else { return [] }
        return SimctlParsing.parseSimulators(data)
    }

    // MARK: Process helper

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Bring-up (delegated to scripts/sim-wda-up.sh)

    private static var stageDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror/wda-stage", isDirectory: true)
    }

    /// Several controllers resolve at once; only one may (re)stage the copy.
    private static let stageLock = NSLock()

    /// The directory to run `scripts/sim-wda-up.sh` from: the repo checkout when
    /// running from source, otherwise a staged copy of the app's bundled
    /// `tools/`+`scripts/`. nil when neither is available. Never on main.
    private static func resolvedRoot() -> URL? {
        let fm = FileManager.default
        // 1. Dev checkout — the repo tree next to this source file.
        let repo = URL(fileURLWithPath: #filePath)          // Sources/iMirror/SimulatorController.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if fm.fileExists(atPath: repo.appendingPathComponent("scripts/sim-wda-up.sh").path) {
            return repo
        }
        // 2. Packaged — stage the bundled copy into a writable dir, once per app build.
        guard let res = Bundle.main.resourceURL,
              fm.fileExists(atPath: res.appendingPathComponent("scripts/sim-wda-up.sh").path)
        else { return nil }
        stageLock.lock(); defer { stageLock.unlock() }
        return stageBundledResources(from: res)
    }

    /// Copy the bundled `tools/`+`scripts/` into `stageDir` when missing or stale
    /// (marker != current app build), then return `stageDir`. nil on copy failure.
    private static func stageBundledResources(from res: URL) -> URL? {
        let fm = FileManager.default
        let dir = stageDir
        let marker = dir.appendingPathComponent(".app-build")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let current = try? String(contentsOf: marker, encoding: .utf8)
        let present = fm.fileExists(atPath: dir.appendingPathComponent("scripts/sim-wda-up.sh").path)
        if !present || !StageMarker.isCurrent(marker: current, appBuild: build) {
            try? fm.removeItem(at: dir)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: res.appendingPathComponent("tools"),
                                to: dir.appendingPathComponent("tools"))
                try fm.copyItem(at: res.appendingPathComponent("scripts"),
                                to: dir.appendingPathComponent("scripts"))
                try build.write(to: marker, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return dir
    }

    /// Boot the sim and bring up WDA on its slot. Safe to call from the main
    /// thread — all blocking work runs on this sim's queue; phases come back via
    /// `onPhase` on the main thread.
    func enable() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            let gen = self.generation
            self.lastPhase = nil
            self.emit(.booting)
            guard Self.xcodeAvailable() else { return self.emit(.failed("Requires Xcode.")) }
            guard let root = Self.resolvedRoot() else {
                return self.emit(.failed("Simulator support isn't available in this build."))
            }
            let script = root.appendingPathComponent("scripts/sim-wda-up.sh")
            let projPath = root.appendingPathComponent("tools/WebDriverAgent/WebDriverAgent.xcodeproj").path
            _ = Self.run("/usr/bin/xcrun", ["simctl", "boot", self.udid])   // no-op if already booted
            _ = Self.run("/usr/bin/open", ["-g", "-a", "Simulator"])

            // The script builds (branding/sign) then execs `xcodebuild test-without-building`,
            // so the child stays alive as long as WDA runs; ManagedProcess restarts it if it dies.
            self.emit(.building)
            let build = self.workDir.appendingPathComponent("build")
            let cmd = "PORT=\(self.slot.wdaPort) MJPEG_PORT=\(self.slot.mjpegPort)"
                + " WDA_SIM_BUILD_DIR='\(Self.shellEscape(build.path))'"
                + " WDA_PROJECT='\(Self.shellEscape(projPath))'"
                + " '\(Self.shellEscape(script.path))' '\(Self.shellEscape(self.udid))'"
            let proc = ManagedProcess(binary: URL(fileURLWithPath: "/bin/bash"),
                                      args: ["-lc", cmd],
                                      label: "sim-wda-\(self.slot.index)", restartDelay: 6,
                                      workDir: self.workDir)
            proc.onGaveUp = { [weak self] _ in
                self?.queue.async {
                    guard let self, self.generation == gen, !self.everReady else { return }
                    self.emit(.failed("WebDriverAgent keeps failing to start (set IMIRROR_DEBUG=1 "
                                      + "and see \(self.workDir.path)/sim-wda-\(self.slot.index).log)"))
                }
            }
            self.wdaLock.lock()
            let old = self.wda
            let quitting = self.quitting
            if !quitting { self.wda = proc }
            self.wdaLock.unlock()
            old?.stop()   // never leak a prior runner on a repeated enable
            guard !quitting else { return }
            self.everReady = false
            self.lastAnswered = ProcessInfo.processInfo.systemUptime
            self.lastBounce = 0
            proc.start()
            self.emit(.starting)
            self.pollTick(gen)
        }
    }

    /// Stop this sim's runner. The sim itself stays booted.
    func disable() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.wdaLock.lock()
            let p = self.wda
            self.wda = nil
            self.wdaLock.unlock()
            p?.stop()
        }
    }

    /// For app quit: stop the runner now, on the caller's thread, without
    /// waiting behind the queue (it may be inside a 30 s `simctl boot`).
    func stopNow() {
        wdaLock.lock()
        quitting = true
        let p = wda
        wda = nil
        wdaLock.unlock()
        p?.stop()
    }

    // MARK: Supervision

    /// Polls /status on this sim's queue for as long as it's enabled: every 2 s
    /// until ready, then every 5 s. ManagedProcess relaunches a runner that
    /// exits; this catches one that is alive but no longer answering.
    private func pollTick(_ gen: Int) {
        guard gen == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if wdaReady() {
            everReady = true
            lastAnswered = now
            emit(.ready)
        } else if everReady {
            emit(.restarting)
            if now - lastAnswered > wedgedAfter, now - lastBounce > bounceCooldown {
                NSLog("iMirror: sim \(udid) WDA silent for \(Int(now - lastAnswered))s — bouncing its runner")
                lastBounce = now
                wdaLock.lock(); let p = wda; wdaLock.unlock()
                p?.bounce()
            }
        }
        queue.asyncAfter(deadline: .now() + (everReady ? 5 : 2)) { [weak self] in self?.pollTick(gen) }
    }

    /// Escape a string for safe embedding inside single quotes in a `bash -lc` command.
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func wdaReady() -> Bool {
        guard let url = URL(string: "\(slot.wdaURL)/status") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { ok = s.contains("\"ready\" : true") || s.contains("\"ready\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return ok
    }

    /// Report a phase change (repeats are dropped). Call on `queue` only.
    private func emit(_ p: SimPhase) {
        guard p != lastPhase else { return }
        lastPhase = p
        DispatchQueue.main.async { self.onPhase?(p) }
    }
}
