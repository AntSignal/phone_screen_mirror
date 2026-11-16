// LockProbe — runs `ios lockdown get PasswordProtected --udid=U` to learn
// whether a phone is locked. It talks to lockdown over usbmux, so it works
// while the shared tunnel is down because the phone is locked. The parse
// and every rule about readings live in iMirrorCore/LockProbe.swift. This
// file only runs the command, with a hard time limit, and never touches a
// passcode or the secrets file.

import Darwin
import Foundation
import iMirrorCore

extension GoIOS {
    /// Run go-ios, killing it once `timeout` passes. GoIOS.run has no
    /// limit, and a probe that hangs must read as "unknown", not block.
    /// Blocking: call off the main thread. stderr is dropped.
    static func runBounded(_ bin: URL, _ args: [String], workDir: URL,
                           timeout: TimeInterval) -> (status: Int32, out: Data, timedOut: Bool) {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = workDir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, Data(), false) }
        var data = Data()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild may hold the pipe open: don't race it.
        let drained = read.wait(timeout: .now() + 1) == .success
        return (timedOut ? -1 : p.terminationStatus, drained ? data : Data(), timedOut || !drained)
    }
}

enum LockProbe {
    /// One reading for `udid`. Blocking: call off the main thread.
    static func read(bin: URL, udid: String, workDir: URL) -> LockReading {
        guard let args = LockProbeParsing.args(udid: udid) else { return .unknown }
        let r = GoIOS.runBounded(bin, args, workDir: workDir, timeout: AutoUnlockTiming.probeTimeoutSec)
        return LockProbeParsing.reading(status: r.status, stdout: r.out, timedOut: r.timedOut)
    }

    /// A probe for one phone: runs off main, answers on main.
    static func make(bin: URL, udid: String, workDir: URL) -> (@escaping (LockReading) -> Void) -> Void {
        { done in
            DispatchQueue.global(qos: .utility).async {
                let r = read(bin: bin, udid: udid, workDir: workDir)
                DispatchQueue.main.async { done(r) }
            }
        }
    }
}
