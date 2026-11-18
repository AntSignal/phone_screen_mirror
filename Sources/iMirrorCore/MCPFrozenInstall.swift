// The rules behind the frozen MCP install: which files are copied, how a copy's
// directory is named, what the device-lease launcher says, and which old copies
// may be deleted. Kept pure so `swift test` covers them; the copying and the
// process spawning live in iMirror/MCPFrozenInstaller.swift.
//
// Why a frozen copy at all: sessions used to run the server straight out of a
// git checkout, so editing or checking out that tree changed what every new
// session (and every run.sh scenario agent) loaded, half-edited files included.

import CryptoKit
import Foundation

public enum MCPFrozenInstall {
    /// The protocol the lease CLI must report. Its consumers parse protocol 1
    /// only, so a copy that says anything else is refused rather than installed.
    public static let leaseProtocol = 1

    /// Pruning keeps at least this many copies...
    public static let keepNewest = 3
    /// ...and anything younger than this. A running server imports sibling
    /// modules from its own copy's real path, so deleting a copy in use breaks it.
    public static let minPruneAge: TimeInterval = 30 * 24 * 3600

    /// Server files only. Tests, pytest's conftest.py and subdirectories such
    /// as testsupport/ stay out: the server must not depend on them at run time.
    public static func isServerFile(_ name: String) -> Bool {
        if name == "requirements.txt" { return true }
        guard name.hasSuffix(".py"), !name.hasPrefix(".") else { return false }
        return !name.hasPrefix("test_") && name != "conftest.py"
    }

    /// sha256 (hex) over the files in name order. Each file adds its name, its
    /// byte count and its bytes, so two different file sets never hash alike.
    public static func contentHash(_ files: [String: Data]) -> String {
        var h = SHA256()
        for name in files.keys.sorted() {
            let data = files[name]!
            h.update(data: Data("\(name)\n\(data.count)\n".utf8))
            h.update(data: data)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The `__version__ = "x"` value of a server script, if it has one.
    public static func serverVersion(in source: String) -> String? {
        let re = try? NSRegularExpression(pattern: #"__version__\s*=\s*["']([^"']+)["']"#)
        let range = NSRange(source.startIndex..., in: source)
        guard let m = re?.firstMatch(in: source, range: range),
              let r = Range(m.range(at: 1), in: source) else { return nil }
        return String(source[r])
    }

    /// `<version>-<hash8>`. The version says which release it is; the hash makes
    /// two builds of one version (it does not change per commit) different dirs.
    public static func versionDirName(version: String?, hash: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String((version ?? "").map { allowed.contains($0) ? $0 : "_" })
        let v = cleaned.isEmpty || cleaned.hasPrefix(".") ? "unknown" : cleaned
        return "\(v)-\(hash.prefix(8))"
    }

    /// True for names `versionDirName` makes. Pruning touches nothing else, so
    /// the venv, `current` and anything a person put there are never deleted.
    public static func isVersionDirName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*-[0-9a-f]{8}$"#, options: .regularExpression) != nil
    }

    /// Single-quotes a string for POSIX sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The `bin/imirror-lease` launcher. Paths are absolute so it works from any
    /// cwd and never follows a git checkout. -I keeps PYTHONPATH and the cwd out.
    /// /usr/bin/python3 is the fallback for a Mac whose venv is gone.
    public static func launcherScript(venvPython: String, leaseScript: String,
                                      fallbackPython: String = "/usr/bin/python3") -> String {
        """
        #!/bin/sh
        # Written by iMirror's MCP installer; rewritten on every install.
        # Runs the device-lease CLI from the frozen copy in mcp/current.
        PY=\(shellQuote(venvPython))
        [ -x "$PY" ] || PY=\(shellQuote(fallbackPython))
        exec "$PY" -I \(shellQuote(leaseScript)) "$@"

        """
    }

    /// The `protocol` from `devicelease.py --version --json`. Reads the last
    /// line that is a JSON object, because stderr noise may share the output.
    public static func leaseProtocol(fromVersionOutput out: String) -> Int? {
        for line in out.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
            else { continue }
            return obj["protocol"] as? Int
        }
        return nil
    }

    /// sha256 (hex) of one blob.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public struct InstalledCopy: Equatable, Sendable {
        public let name: String
        /// When this copy was last installed or reinstalled.
        public let installedAt: Date
        public init(name: String, installedAt: Date) { self.name = name; self.installedAt = installedAt }
    }

    /// Copies to delete: never the one `current` names, never the newest `keep`,
    /// and never one installed within `minAge`.
    public static func copiesToPrune(_ copies: [InstalledCopy], current: String?, now: Date,
                                     keep: Int = keepNewest,
                                     minAge: TimeInterval = minPruneAge) -> [String] {
        let ours = copies.filter { isVersionDirName($0.name) }
            .sorted { $0.installedAt > $1.installedAt }
        return ours.dropFirst(keep)
            .filter { $0.name != current && now.timeIntervalSince($0.installedAt) > minAge }
            .map(\.name)
    }
}
