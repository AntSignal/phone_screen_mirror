import Foundation

// The device file the app publishes for the MCP server:
// ~/Library/Application Support/iMirror/devices.json.
//
// It is the whole contract between the app and mcp-server/imirror_mcp.py
// (`_Registry` there reads exactly these keys). Both sides test against the
// same golden file, mcp-server/testdata/devices.sample.json: Swift encodes it
// byte-for-byte, Python decodes it — so a key renamed on one side fails a test
// on the other instead of silently dropping a phone.
//
// Keys added since schema 1 are optional and additive, so the schema stays 1
// and older readers ignore what they do not know.

/// One phone (or the Simulator) the app is running WebDriverAgent on.
public struct RegisteredDevice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case device, simulator }

    /// Where the app is in bringing this device's WDA up. The MCP server only
    /// shows it in errors and `ios_devices`; it never refuses a call on it,
    /// because /status is the real answer.
    public enum State: String, Codable, Sendable {
        case starting, installing, ready, down, failed
    }

    public var udid: String
    public var alias: String
    public var kind: Kind
    public var productType: String?
    public var iosVersion: String?
    public var connection: String?
    public var slot: Int?
    /// Loopback base URL of this device's WDA — the app's in-process relay.
    public var wdaURL: String
    public var mjpegPort: Int?
    public var state: State
    public var detail: String?
    /// Why the device is not ready: a `DeviceReason` raw value. A String so
    /// a reader never fails on a reason a newer app adds.
    public var reason: String?
    /// When `state` or `reason` last changed (UTC ISO-8601).
    public var stateSince: String?
    /// Goes up by one each time this phone's chain starts.
    public var chainEpoch: Int?
    /// The last error worth showing, short and secret-free.
    public var lastError: String?
    /// When a given-up phone retries by itself (UTC ISO-8601).
    public var nextRetryAt: String?
    /// `AutoUnlockState` raw value, only for a phone with a keyboard
    /// pairing. A String so an unknown value never fails a reader.
    public var autoUnlock: String?

    public init(udid: String, alias: String, kind: Kind, productType: String? = nil,
                iosVersion: String? = nil, connection: String? = nil, slot: Int? = nil,
                wdaURL: String, mjpegPort: Int? = nil, state: State, detail: String? = nil,
                reason: String? = nil, stateSince: String? = nil, chainEpoch: Int? = nil,
                lastError: String? = nil, nextRetryAt: String? = nil, autoUnlock: String? = nil) {
        self.udid = udid; self.alias = alias; self.kind = kind
        self.productType = productType; self.iosVersion = iosVersion
        self.connection = connection; self.slot = slot; self.wdaURL = wdaURL
        self.mjpegPort = mjpegPort; self.state = state; self.detail = detail
        self.reason = reason; self.stateSince = stateSince; self.chainEpoch = chainEpoch
        self.lastError = lastError; self.nextRetryAt = nextRetryAt
        self.autoUnlock = autoUnlock
    }

    enum CodingKeys: String, CodingKey {
        case udid, alias, kind, connection, slot, state, detail, reason
        case productType = "product_type"
        case iosVersion = "ios_version"
        case wdaURL = "wda_url"
        case mjpegPort = "mjpeg_port"
        case stateSince = "state_since"
        case chainEpoch = "chain_epoch"
        case lastError = "last_error"
        case nextRetryAt = "next_retry_at"
        case autoUnlock = "auto_unlock"
    }
}

/// Something that keeps the app from driving a phone, or any phone, that
/// no device entry can say: a phone that got no slot has no entry at all.
public struct RegistryProblem: Codable, Equatable, Sendable {
    /// The phone it is about; nil when it is about the app itself.
    public var udid: String?
    /// A `RegistryProblem.Reason` raw value. A String so a reader never
    /// fails on a reason a newer app adds.
    public var reason: String
    public var message: String

    public enum Reason: String, Sendable {
        /// The phone's sticky port is held by another process.
        case slotConflict = "slot_conflict"
        /// Every port slot belongs to an attached phone.
        case slotsFull = "slots_full"
        /// The go-ios binary the app runs is gone (its bundle was deleted).
        case appBundleMissing = "app_bundle_missing"
    }

    public init(udid: String?, reason: Reason, message: String) {
        self.udid = udid; self.reason = reason.rawValue; self.message = message
    }

    /// The problem a slot assignment leaves, or nil when it got a slot.
    public static func slot(_ result: SlotAssignment, udid: String) -> RegistryProblem? {
        switch result {
        case .assigned:
            return nil
        case .conflict(let slot, let port):
            return RegistryProblem(udid: udid, reason: .slotConflict,
                                   message: "port \(port) (its slot \(slot.index)) is held by another process")
        case .full:
            return RegistryProblem(udid: udid, reason: .slotsFull,
                                   message: "all \(PortSlot.maxSlots) port slots belong to attached phones")
        }
    }

    public static func appBundleMissing(goios: String) -> RegistryProblem {
        RegistryProblem(udid: nil, reason: .appBundleMissing,
                        message: "iMirror's go-ios binary (\(goios)) is gone: the app bundle was deleted or "
                            + "moved. No phone can start until iMirror restarts: scripts/run.sh --restart")
    }

    /// The file's list: the app-wide problem first, then phones by UDID,
    /// so the bytes only change when a problem does.
    public static func list(bundle: RegistryProblem?, phones: [String: RegistryProblem]) -> [RegistryProblem] {
        (bundle.map { [$0] } ?? []) + phones.keys.sorted().compactMap { phones[$0] }
    }
}

/// Watches that the app's go-ios binary is still on disk. A deleted
/// bundle is told once per run: the fix, a restart, ends the run anyway.
public struct AppBundleWatch: Equatable, Sendable {
    public private(set) var missing = false
    public private(set) var notified = false

    public init() {}

    /// Record one check. True when the user must be told now.
    public mutating func check(binaryExists: Bool) -> Bool {
        missing = !binaryExists
        guard missing, !notified else { return false }
        notified = true
        return true
    }
}

/// The whole file. `ownerPid` lets a reader tell a live list from one a
/// crashed app left behind: the MCP server ignores the file unless that
/// process is alive. `ownerUniqueID` (the kernel's p_uniqueid, never reused
/// within a boot) also catches a pid the system has handed to someone else.
public struct DeviceRegistryFile: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var ownerPid: Int32
    public var ownerUniqueID: UInt64?
    public var appVersion: String
    public var updatedAt: String
    /// The go-ios binary the app drives, so `ios_install_app` uses the same one.
    public var goios: String?
    public var devices: [RegisteredDevice]
    /// What stops a phone, or every phone, from starting. Absent in older
    /// app builds, so readers must treat a missing key as none.
    public var problems: [RegistryProblem]?

    public init(ownerPid: Int32, ownerUniqueID: UInt64? = nil, appVersion: String, updatedAt: String,
                goios: String?, devices: [RegisteredDevice], problems: [RegistryProblem]? = nil,
                schema: Int = DeviceRegistryFile.schemaVersion) {
        self.schema = schema; self.ownerPid = ownerPid; self.ownerUniqueID = ownerUniqueID
        self.appVersion = appVersion; self.updatedAt = updatedAt; self.goios = goios
        self.devices = devices; self.problems = problems
    }

    enum CodingKeys: String, CodingKey {
        case schema, goios, devices, problems
        case ownerPid = "owner_pid"
        case ownerUniqueID = "owner_uniqueid"
        case appVersion = "app_version"
        case updatedAt = "updated_at"
    }
}

public enum DeviceRegistryCodec {
    /// Pretty, key-sorted and slash-unescaped: stable bytes for the golden
    /// test, and readable when someone opens the file to see what's attached.
    public static func encode(_ file: DeviceRegistryFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> DeviceRegistryFile {
        try JSONDecoder().decode(DeviceRegistryFile.self, from: data)
    }

    /// ISO-8601 in UTC, whole seconds — informational only; nothing orders on it
    /// (a Mac's clock can jump, the owner pid is what readers trust).
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
