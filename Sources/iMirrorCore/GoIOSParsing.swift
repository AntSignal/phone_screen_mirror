import Foundation

// Pure parsers for go-ios output, so device discovery unit-tests against
// canned bytes. The app shells out and hands the bytes here.

/// A phone go-ios can see (`ios list --details`).
public struct AttachedDevice: Equatable, Sendable {
    public let udid: String
    public let productType: String?
    public let productVersion: String?
    /// "USB" or "Network" (empty when go-ios didn't say).
    public let connection: String

    public init(udid: String, productType: String?, productVersion: String?, connection: String) {
        self.udid = udid; self.productType = productType
        self.productVersion = productVersion; self.connection = connection
    }

    /// Only USB phones get a chain: the tunnel and forwards ride the cable.
    public var isUSB: Bool { connection.caseInsensitiveCompare("USB") == .orderedSame }
}

public enum GoIOSParsing {
    /// Parse `ios list [--details]`. Accepts `{"deviceList": [...]}` with either
    /// UDID strings or detail objects, tolerates go-ios log lines around the
    /// JSON, and lists a phone seen over both USB and the network once, as USB.
    public static func attachedDevices(fromListDetails data: Data) -> [AttachedDevice] {
        guard let list = firstJSONObject(in: data, withKey: "deviceList")?["deviceList"] as? [Any]
        else { return [] }
        var out: [AttachedDevice] = []
        var index: [String: Int] = [:]
        for item in list {
            let device: AttachedDevice
            if let udid = item as? String {
                device = AttachedDevice(udid: udid, productType: nil, productVersion: nil, connection: "")
            } else if let d = item as? [String: Any], let udid = d["Udid"] as? String, !udid.isEmpty {
                device = AttachedDevice(udid: udid, productType: d["ProductType"] as? String,
                                        productVersion: d["ProductVersion"] as? String,
                                        connection: d["ConnectionType"] as? String ?? "")
            } else {
                continue
            }
            if let i = index[device.udid] {
                if device.isUSB && !out[i].isUSB { out[i] = device }
            } else {
                index[device.udid] = out.count
                out.append(device)
            }
        }
        return out
    }

    /// The UDIDs with an established tunnel, from the tunnel agent's
    /// `GET /tunnels` (a JSON array of `{"udid": …, "rsdPort": …}`).
    public static func tunnelUDIDs(fromTunnels data: Data) -> Set<String> {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0["udid"] as? String }.filter { !$0.isEmpty })
    }

    /// go-ios prints JSON log lines and its result on the same streams; take the
    /// first line that is a JSON object carrying `key`.
    private static func firstJSONObject(in data: Data, withKey key: String) -> [String: Any]? {
        if let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any], whole[key] != nil {
            return whole
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj[key] != nil else { continue }
            return obj
        }
        return nil
    }
}
