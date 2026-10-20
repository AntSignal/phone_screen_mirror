// Installs the MCP server as a frozen copy and points mcp/current at it:
//
//   <base>/mcp/<version>-<hash8>/            one copy per distinct set of files
//   <base>/mcp/current -> <version>-<hash8>  what every client runs
//   <base>/mcp/.venv/                        the shared Python environment
//   <base>/bin/imirror-lease                 device-lease CLI, when shipped
//
// A copy becomes `current` only after the venv's Python has imported it, so a
// broken build cannot take the tools away from every new session. The rules
// (which files, names, launcher text, pruning) are pure, in
// iMirrorCore/MCPFrozenInstall.swift.

import Foundation
import iMirrorCore

struct MCPFrozenInstaller {
    struct Outcome { let ok: Bool; let message: String }

    typealias Runner = (_ launch: String, _ args: [String], _ timeout: TimeInterval?)
        -> (code: Int32, out: String)

    var layout: MCPLayout
    var run: Runner = { ProcessRunner.spawn($0, $1, timeout: $2) }
    var now: () -> Date = Date.init
    /// Seconds the import and the lease check each get before they are killed.
    var smokeTimeout: TimeInterval = 60

    private var fm: FileManager { .default }

    // MARK: Reading

    /// The server files directly inside `dir`, by name.
    func serverFiles(in dir: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try fm.contentsOfDirectory(atPath: dir.path) where MCPFrozenInstall.isServerFile(name) {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            files[name] = try Data(contentsOf: url)
        }
        return files
    }

    func dirName(for files: [String: Data]) -> String {
        let version = files["imirror_mcp.py"].flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(MCPFrozenInstall.serverVersion(in:))
        return MCPFrozenInstall.versionDirName(version: version,
                                               hash: MCPFrozenInstall.contentHash(files))
    }

    /// The copy an install from `sourceDir` would make, or nil if it can't.
    func plannedDirName(sourceDir: URL) -> String? {
        guard let files = try? serverFiles(in: sourceDir), files["imirror_mcp.py"] != nil else { return nil }
        return dirName(for: files)
    }

    /// The copy `current` points at, or nil when there is none.
    func currentDirName() -> String? {
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: layout.currentLink.path) else { return nil }
        let name = URL(fileURLWithPath: dest).lastPathComponent
        return fm.fileExists(atPath: layout.mcpRoot.appendingPathComponent(name).path) ? name : nil
    }

    // MARK: Installing

    /// Copy, sync deps, smoke-test, swap `current`, write the launcher, prune.
    /// Every failure before the swap leaves `current` exactly as it was.
    func install(from sourceDir: URL, progress: (String) -> Void = { _ in }) -> Outcome {
        let files: [String: Data]
        do { files = try serverFiles(in: sourceDir) } catch {
            return Outcome(ok: false, message: "Couldn't read \(sourceDir.path): \(error.localizedDescription)")
        }
        guard files["imirror_mcp.py"] != nil else {
            return Outcome(ok: false, message: "No imirror_mcp.py in \(sourceDir.path).")
        }
        let name = dirName(for: files)
        let hasLease = files["devicelease.py"] != nil

        progress("Copying the server (\(name))…")
        let dir: URL
        do { dir = try stage(files, as: name) } catch {
            return Outcome(ok: false, message: "Copying the server failed: \(error.localizedDescription)")
        }
        if let failure = syncRequirements(in: dir, progress: progress) { return failure }

        progress("Checking the new copy…")
        if let why = smokeTest(dir, hasLease: hasLease) {
            // The fault may be the venv, so the next try reinstalls deps.
            try? fm.removeItem(at: layout.requirementsHashFile)
            let kept = currentDirName().map { "still runs \($0)" } ?? "has nothing installed"
            return Outcome(ok: false, message: "Didn't install \(name): \(why). The MCP install \(kept).")
        }
        do { try swapCurrent(to: name) } catch {
            return Outcome(ok: false, message: "Didn't install \(name): \(error.localizedDescription)")
        }
        do { try updateLauncher(hasLease: hasLease) } catch {
            return Outcome(ok: false, message: "Installed \(name), but writing bin/imirror-lease failed: "
                           + error.localizedDescription)
        }
        prune()
        return Outcome(ok: true, message: name)
    }

    /// Writes `files` into mcp/<name>/ through a hidden staging dir, so the
    /// named dir is either complete or absent. An existing dir is reused only
    /// if its files match, since the name promises what they are.
    func stage(_ files: [String: Data], as name: String) throws -> URL {
        let dest = layout.mcpRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: layout.mcpRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            if (try? serverFiles(in: dest)) == files {
                // Reinstalled, so pruning should treat it as new.
                try? fm.setAttributes([.modificationDate: now()], ofItemAtPath: dest.path)
                return dest
            }
            try fm.removeItem(at: dest)
        }
        let staging = layout.mcpRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for (file, data) in files { try data.write(to: staging.appendingPathComponent(file)) }
            try fm.moveItem(at: staging, to: dest)
        } catch {
            try? fm.removeItem(at: staging)
            // A second install (device and sim at once) may have won the race.
            if (try? serverFiles(in: dest)) == files { return dest }
            throw error
        }
        return dest
    }

    /// Runs pip only when requirements.txt differs from what the venv last
    /// got, so pressing Update does not quietly upgrade mcp under every new
    /// session. Returns a failure, or nil to carry on.
    private func syncRequirements(in dir: URL, progress: (String) -> Void) -> Outcome? {
        let reqs = dir.appendingPathComponent("requirements.txt")
        let reqData = try? Data(contentsOf: reqs)
        let want = MCPFrozenInstall.sha256Hex(reqData ?? Data("mcp[cli]".utf8))
        let have = (try? String(contentsOf: layout.requirementsHashFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard have != want else { return nil }

        progress("Installing dependencies (mcp)…")
        let py = layout.venvPython.path
        _ = run(py, ["-m", "pip", "install", "--upgrade", "pip"], nil)   // old pip can't resolve mcp
        var args = ["-m", "pip", "install", "--upgrade"]
        if reqData != nil { args += ["-r", reqs.path] } else { args.append("mcp[cli]") }
        let pip = run(py, args, nil)
        guard pip.code == 0 else {
            return Outcome(ok: false, message: "pip install failed: \(MCPInstaller.firstError(pip.out))")
        }
        try? Data((want + "\n").utf8).write(to: layout.requirementsHashFile, options: .atomic)
        return nil
    }

    /// Nil when the copy works, else why not. It imports the server with the
    /// venv's Python, copy first on sys.path, then asks the lease CLI for its
    /// protocol. A copy missing a module therefore never becomes `current`.
    func smokeTest(_ dir: URL, hasLease: Bool) -> String? {
        let py = layout.venvPython.path
        let imp = run(py, ["-I", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import imirror_mcp",
                           dir.path], smokeTimeout)
        guard imp.code == 0 else { return "importing imirror_mcp failed (\(lastLine(imp.out)))" }
        guard hasLease else { return nil }
        let lease = run(py, ["-I", dir.appendingPathComponent("devicelease.py").path, "--version", "--json"],
                        smokeTimeout)
        let proto = MCPFrozenInstall.leaseProtocol(fromVersionOutput: lease.out)
        guard lease.code == 0, proto == MCPFrozenInstall.leaseProtocol else {
            return "devicelease.py --version --json exited \(lease.code) with protocol "
                + "\(proto.map(String.init) ?? "missing"), not \(MCPFrozenInstall.leaseProtocol)"
        }
        return nil
    }

    /// Points `current` at `name` with one rename(2), so a client starting at
    /// any moment finds the old copy or the new one, never neither.
    func swapCurrent(to name: String) throws {
        let link = layout.currentLink
        if let attrs = try? fm.attributesOfItem(atPath: link.path),
           attrs[.type] as? FileAttributeType != .typeSymbolicLink {
            // rename(2) can't replace a real directory; keep it, out of the way.
            let aside = layout.mcpRoot.appendingPathComponent("current.replaced-\(Int(now().timeIntervalSince1970))")
            try fm.moveItem(at: link, to: aside)
        }
        let tmp = layout.mcpRoot.appendingPathComponent(".current-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: tmp.path, withDestinationPath: name)   // relative to mcp/
        try renameOver(tmp, link)
    }

    /// Writes bin/imirror-lease when the copy ships devicelease.py, else removes
    /// it: a launcher whose script is missing reads as a broken lease system
    /// (fail closed) instead of an absent one.
    func updateLauncher(hasLease: Bool) throws {
        let url = layout.leaseLauncher
        guard hasLease else {
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = MCPFrozenInstall.launcherScript(
            venvPython: layout.venvPython.path,
            leaseScript: layout.currentLink.appendingPathComponent("devicelease.py").path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".imirror-lease-\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        try renameOver(tmp, url)
    }

    /// Deletes old copies (rules in MCPFrozenInstall.copiesToPrune) and what an
    /// interrupted install left behind. Best effort: a failure here is harmless.
    func prune() {
        guard let names = try? fm.contentsOfDirectory(atPath: layout.mcpRoot.path) else { return }
        var copies: [MCPFrozenInstall.InstalledCopy] = []
        for name in names {
            let url = layout.mcpRoot.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let at = (attrs[.modificationDate] as? Date) ?? now()
            if name.hasPrefix(".staging-") || name.hasPrefix(".current-") {
                // An hour old means no install is still using it.
                if now().timeIntervalSince(at) > 3600 { try? fm.removeItem(at: url) }
                continue
            }
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { continue }
            copies.append(.init(name: name, installedAt: at))
        }
        for name in MCPFrozenInstall.copiesToPrune(copies, current: currentDirName(), now: now()) {
            try? fm.removeItem(at: layout.mcpRoot.appendingPathComponent(name))
        }
    }

    // MARK: Helpers

    private func renameOver(_ from: URL, _ to: URL) throws {
        guard rename(from.path, to.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: from)
            throw NSError(domain: "MCPFrozenInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "replacing \(to.path): \(why)"])
        }
    }

    /// A Python traceback's last line names the error.
    private func lastLine(_ out: String) -> String {
        let line = out.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no output"
        return String(line.prefix(200))
    }
}
