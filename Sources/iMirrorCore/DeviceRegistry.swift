import Foundation

// The device file the app publishes for the MCP server:
// ~/Library/Application Support/iMirror/devices.json.
//
// It is the whole contract between the app and mcp-server/imirror_mcp.py
// (`_Registry` there reads exactly these keys). Both sides test against the
// same golden file, mcp-server/testdata/devices.sample.json: Swift encodes it
// byte-for-byte, Python decodes it — so a key renamed on one side fails a test
// on the other instead of silently dropping a phone.

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

    public init(udid: String, alias: String, kind: Kind, productType: String? = nil,
                iosVersion: String? = nil, connection: String? = nil, slot: Int? = nil,
                wdaURL: String, mjpegPort: Int? = nil, state: State, detail: String? = nil) {
        self.udid = udid; self.alias = alias; self.kind = kind
        self.productType = productType; self.iosVersion = iosVersion
        self.connection = connection; self.slot = slot; self.wdaURL = wdaURL
        self.mjpegPort = mjpegPort; self.state = state; self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case udid, alias, kind, connection, slot, state, detail
        case productType = "product_type"
        case iosVersion = "ios_version"
        case wdaURL = "wda_url"
        case mjpegPort = "mjpeg_port"
    }
}

/// The whole file. `ownerPid` lets a reader tell a live list from one a
/// crashed app left behind: the MCP server ignores the file unless that
/// process is alive.
public struct DeviceRegistryFile: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var ownerPid: Int32
    public var appVersion: String
    public var updatedAt: String
    /// The go-ios binary the app drives, so `ios_install_app` uses the same one.
    public var goios: String?
    public var devices: [RegisteredDevice]

    public init(ownerPid: Int32, appVersion: String, updatedAt: String, goios: String?,
                devices: [RegisteredDevice], schema: Int = DeviceRegistryFile.schemaVersion) {
        self.schema = schema; self.ownerPid = ownerPid; self.appVersion = appVersion
        self.updatedAt = updatedAt; self.goios = goios; self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case schema, goios, devices
        case ownerPid = "owner_pid"
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
