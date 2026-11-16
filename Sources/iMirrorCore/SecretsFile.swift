import Foundation

// SecretsFile — reads one phone's passcode from a dotenv-style file for
// Settings → "Type passcode now" and for auto-unlock. The value must never reach a log, an
// event, argv or a description, so it is kept as bytes in SecretBytes, which
// prints as a count and is zeroed when done. Swift may still leave copies
// (Data, temporaries); zeroing only shortens how long the value sits around.

/// Bytes that hold a secret. Prints, debug-prints and mirrors as a count.
public final class SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public private(set) var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    deinit { wipe() }

    public var count: Int { bytes.count }

    /// Zero the bytes in place, then drop them.
    public func wipe() {
        SecretsFile.zero(&bytes)
        bytes = []
    }

    public var description: String { "<secret: \(bytes.count) chars>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["count": bytes.count]) }
}

public enum SecretsFile {
    /// The value of `key`, or nil when it is missing or empty. A subset of
    /// dotenv: `KEY=VALUE`, an optional `export `, "double" (with \" and \\)
    /// or 'single' quotes, `#` comment lines and ` #` after an unquoted
    /// value. The last line for a key wins, as when a shell sources it.
    /// Lines for other keys are never parsed past their name.
    public static func value(forKey key: String, in text: [UInt8]) -> SecretBytes? {
        let name = Array(key.utf8)
        var found: [UInt8]?
        var start = 0
        while start < text.count {
            var end = start
            while end < text.count, text[end] != 0x0A { end += 1 }
            if let v = parse(text, start, end, name) {
                // Zero in place; a copy would leave the old value.
                if found != nil { zero(&found!) }
                found = v
            }
            start = end + 1
        }
        guard let v = found, !v.isEmpty else { return nil }
        found = nil   // the SecretBytes now owns the only copy
        return SecretBytes(v)
    }

    /// Overwrite every byte with zero, keeping the length.
    public static func zero(_ a: inout [UInt8]) {
        a.withUnsafeMutableBufferPointer { buf in for i in buf.indices { buf[i] = 0 } }
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
    private static func isNameByte(_ b: UInt8, first: Bool) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || (!first && b >= 0x30 && b <= 0x39)
    }

    /// The value on line [s, e) if it sets `name`, else nil.
    private static func parse(_ t: [UInt8], _ s: Int, _ e: Int, _ name: [UInt8]) -> [UInt8]? {
        var i = s
        while i < e, isSpace(t[i]) { i += 1 }
        let export = Array("export".utf8)
        if i + export.count < e, Array(t[i..<i + export.count]) == export, isSpace(t[i + export.count]) {
            i += export.count
            while i < e, isSpace(t[i]) { i += 1 }
        }
        let nameStart = i
        while i < e, isNameByte(t[i], first: i == nameStart) { i += 1 }
        guard i > nameStart, Array(t[nameStart..<i]) == name else { return nil }
        while i < e, isSpace(t[i]) { i += 1 }
        guard i < e, t[i] == 0x3D else { return nil }   // "="
        i += 1
        while i < e, isSpace(t[i]) { i += 1 }
        var out: [UInt8] = []
        if i < e, t[i] == 0x22 || t[i] == 0x27 {        // " or '
            let q = t[i]
            i += 1
            while i < e, t[i] != q {
                // Double quotes take \" and \\; single quotes are literal.
                if q == 0x22, t[i] == 0x5C, i + 1 < e, t[i + 1] == 0x22 || t[i + 1] == 0x5C { i += 1 }
                out.append(t[i])
                i += 1
            }
            guard i < e else { zero(&out); return nil }  // no closing quote
            return out
        }
        while i < e {
            if t[i] == 0x23, let last = out.last, isSpace(last) { break }   // " #" comment
            out.append(t[i])
            i += 1
        }
        while let last = out.last, isSpace(last) { out.removeLast() }
        return out
    }
}

/// Where a phone's passcode comes from.
public enum PasscodeLookup {
    public static let fallbackKey = "ANTSIGNAL_TEST_DEVICE_PASSCODE"
    public static let fallbackUDIDKey = "ANTSIGNAL_DEVICE_UDID"

    public enum Result {
        case found(SecretBytes)
        /// The file is missing or unreadable.
        case noFile
        case noPasscode
    }

    /// IMIRROR_PASSCODE_ plus the UDID without dashes, upper-cased.
    public static func key(udid: String) -> String {
        "IMIRROR_PASSCODE_" + udid.replacingOccurrences(of: "-", with: "").uppercased()
    }

    /// The short key people write: phone2 -> PHONE2_PASSCODE. Safe because
    /// an alias belongs to one UDID at a time (validateAlias).
    public static func key(alias: String) -> String? {
        let name = alias.uppercased().replacingOccurrences(of: "-", with: "_")
        guard name.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil else { return nil }
        return name + "_PASSCODE"
    }

    /// The key to tell people to add.
    public static func suggestedKey(udid: String, alias: String?) -> String {
        alias.flatMap { key(alias: $0) } ?? key(udid: udid)
    }

    /// This phone's alias key (PHONE2_PASSCODE), then its UDID key. The shared Ant Signal key only counts when
    /// the file says it belongs to this phone, so it is never typed into
    /// another phone (a wrong passcode there is a wrong attempt).
    public static func value(udid: String, alias: String? = nil, in text: [UInt8]) -> SecretBytes? {
        if let k = alias.flatMap({ key(alias: $0) }), let v = SecretsFile.value(forKey: k, in: text) { return v }
        if let v = SecretsFile.value(forKey: key(udid: udid), in: text) { return v }
        guard let owner = SecretsFile.value(forKey: fallbackUDIDKey, in: text) else { return nil }
        let ownerUDID = String(decoding: owner.bytes, as: UTF8.self)
        guard key(udid: ownerUDID) == key(udid: udid) else { return nil }
        return SecretsFile.value(forKey: fallbackKey, in: text)
    }

    /// Reads `file` and returns the passcode for `udid`. The file's bytes are
    /// zeroed before returning.
    public static func load(udid: String, alias: String? = nil, file: URL) -> Result {
        guard var data = try? Data(contentsOf: file) else { return .noFile }
        var text = [UInt8](data)
        data.resetBytes(in: 0..<data.count)
        defer { SecretsFile.zero(&text) }
        return value(udid: udid, alias: alias, in: text).map(Result.found) ?? .noPasscode
    }
}

/// The secrets-file path Settings uses.
public enum PasscodeFile {
    /// UserDefaults key for the path typed in Settings.
    public static let defaultsKey = "imirror.passcodeFile"
    /// The Ant Signal test harness's local secrets file.
    public static let defaultPath = "~/Documents/Github/Purpose/Purpose-iOS/Testing/.env.local"

    /// The stored path, or the default when none; `~` expanded.
    public static func url(stored: String?) -> URL {
        let raw = stored?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(fileURLWithPath: ((raw.isEmpty ? defaultPath : raw) as NSString).expandingTildeInPath)
    }
}
