// Shared filesystem locations for the MCP installer and its client adapters.
// Kept as pure data (no side effects beyond reading the filesystem to locate
// the server script) so MCPInstaller.swift and the per-client adapters in
// this directory agree on where the venv, script, and Claude Desktop config
// live, instead of each recomputing it.

import Foundation

/// Where one frozen MCP install lives, under one base directory. The app uses
/// ~/Library/Application Support/iMirror; tests pass a temp directory.
struct MCPLayout {
    let base: URL

    var mcpRoot: URL { base.appendingPathComponent("mcp", isDirectory: true) }
    var venvDir: URL { mcpRoot.appendingPathComponent(".venv", isDirectory: true) }
    var venvPython: URL { venvDir.appendingPathComponent("bin/python") }
    /// sha256 of the requirements.txt pip last installed into the venv.
    var requirementsHashFile: URL { venvDir.appendingPathComponent(".imirror-requirements.sha256") }
    /// Symlink to the copy sessions run (`<version>-<hash8>`).
    var currentLink: URL { mcpRoot.appendingPathComponent("current") }
    var registeredScript: URL { currentLink.appendingPathComponent("imirror_mcp.py") }
    var leaseLauncher: URL { base.appendingPathComponent("bin/imirror-lease") }
}

enum MCPPaths {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMirror", isDirectory: true)
    }
    static var layout: MCPLayout { MCPLayout(base: appSupport) }
    static var venvDir: URL { layout.venvDir }
    static var venvPython: URL { layout.venvPython }

    static var claudeDesktopConfig: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    /// What clients run: the frozen copy behind mcp/current. It is a constant,
    /// with no override, so an app built in some other tree can never re-point
    /// a registration at that tree, and "Update" never points one back at a dev
    /// checkout.
    static func registeredScriptURL() -> URL { layout.registeredScript }

    /// What gets copied into a frozen install. The copy bundled into iMirror.app
    /// comes first (see scripts/run.sh), because it was taken when this app was
    /// built; a checkout's files may have been edited since. `swift test` and
    /// `swift run` have no bundle, so they use this repo's mcp-server/.
    static func sourceScriptURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mcp-server/imirror_mcp.py"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let repo = URL(fileURLWithPath: #filePath)            // Sources/iMirror/MCPPaths.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mcp-server/imirror_mcp.py")
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        return nil
    }
}
