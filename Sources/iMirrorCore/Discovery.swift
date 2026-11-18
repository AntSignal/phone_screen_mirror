import Foundation

// How one discovery poll's go-ios output becomes the phone list that
// ChainManager reconciles. Pure, so every failure mode is a unit test.
//
// `ios list --details` asks every phone for its lockdown values and exits
// non-zero if any ONE of them fails (go-ios main.go, outputDetailedList), so a
// phone on Wi-Fi only could hide every USB phone. Then the poll falls back to
// plain `ios list` (UDIDs only, from usbmuxd, which cannot fail per phone) and
// `ios info --udid=U` for phones it knows nothing about yet.

/// Time limits for the poll's go-ios calls. A hung call once left the poll
/// stuck for good, since a new poll waits for the old one.
public enum DiscoveryTiming {
    /// `list --details` opens lockdown on every phone, Wi-Fi ones too.
    public static let detailsTimeoutSec: TimeInterval = 10
    /// Plain `list` only asks usbmuxd.
    public static let listTimeoutSec: TimeInterval = 5
    /// One phone's `ios info`; these run side by side.
    public static let infoTimeoutSec: TimeInterval = 5
}

/// What `ios info --udid=U` tells us. It has no connection type.
public struct DeviceProduct: Equatable, Sendable {
    public let productType: String?
    public let productVersion: String?
    public init(productType: String?, productVersion: String?) {
        self.productType = productType; self.productVersion = productVersion
    }
}

/// What one poll managed to read.
public enum DiscoveryListing: Equatable, Sendable {
    /// `list --details` worked.
    case details([AttachedDevice])
    /// Only plain `list` worked. `info` holds the phones whose `ios info` worked.
    case udidsOnly([String], info: [String: DeviceProduct])
    /// Nothing usable: both lists failed or timed out.
    case failed
}

/// The list to reconcile, and what to remember for later polls.
public struct DiscoveryResult: Equatable, Sendable {
    /// USB phones with known details, in go-ios's order.
    public var usb: [AttachedDevice]
    /// Seen, but not known to be USB with details. Keep any chain they have,
    /// count no miss, and start nothing until their details arrive.
    public var held: [String]
    /// Details learned this poll, to merge into the known list.
    public var learned: [AttachedDevice]
}

public enum Discovery {
    /// Merge one poll. nil means "no news": change nothing, tear nothing down.
    /// A failed poll says nothing about what is attached, so it is never a
    /// miss, however many come in a row; the last known list stays.
    /// `usbSerials` is IOKit's view of the Apple USB devices plugged in now.
    public static func merge(_ listing: DiscoveryListing, usbSerials: Set<String>,
                             known: [String: AttachedDevice]) -> DiscoveryResult? {
        switch listing {
        case .failed:
            return nil
        case .details(let all):
            return DiscoveryResult(usb: all.filter(\.isUSB), held: [], learned: all)
        case .udidsOnly(let udids, let info):
            var usb: [AttachedDevice] = [], held: [String] = [], learned: [AttachedDevice] = []
            var seen = Set<String>()
            for udid in udids where seen.insert(udid).inserted {
                let onUSB = usbSerials.contains { usbSerial($0, matchesUDID: udid) }
                let old = known[udid]
                // IOKit sees it: USB. Else the last known type.
                let connection = onUSB ? "USB" : (old?.connection ?? "")
                let product = info[udid] ?? old.map {
                    DeviceProduct(productType: $0.productType, productVersion: $0.productVersion)
                }
                guard let product, !connection.isEmpty else {
                    // Unreadable: hold it only if it may be USB.
                    if onUSB || old?.isUSB == true { held.append(udid) }
                    continue
                }
                let device = AttachedDevice(udid: udid, productType: product.productType,
                                            productVersion: product.productVersion, connection: connection)
                if info[udid] != nil || onUSB { learned.append(device) }
                if device.isUSB && !onUSB {
                    // IOKit lost it: maybe Wi-Fi now. Keep, start nothing.
                    held.append(udid)
                } else if device.isUSB {
                    usb.append(device)
                }
            }
            return DiscoveryResult(usb: usb, held: held, learned: learned)
        }
    }

    /// Phones in a plain `list` that need `ios info`: those we hold no
    /// details for. Known phones skip it, to keep lockdown traffic down.
    public static func needsInfo(_ udids: [String], known: [String: AttachedDevice]) -> [String] {
        var seen = Set<String>()
        return udids.filter { seen.insert($0).inserted && known[$0]?.productVersion == nil }
    }
}

extension GoIOSParsing {
    /// Parse `ios info --udid=U`: one JSON object of lockdown values.
    /// nil when there is no object with a ProductVersion in it.
    public static func deviceProduct(fromInfo data: Data) -> DeviceProduct? {
        guard let obj = firstJSONObject(in: data, withKey: "ProductVersion"),
              let version = obj["ProductVersion"] as? String, !version.isEmpty else { return nil }
        return DeviceProduct(productType: obj["ProductType"] as? String, productVersion: version)
    }
}
