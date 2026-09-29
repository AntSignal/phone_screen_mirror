import CoreGraphics
import Foundation

/// Pure parsers for WebDriverAgent JSON responses — WDA wraps payloads in a
/// "value" object but not always, so each tolerates both shapes.
public enum WDAParse {
    public static func sessionId(_ json: [String: Any]?) -> String? {
        let value = (json?["value"] as? [String: Any]) ?? json ?? [:]
        return (value["sessionId"] as? String) ?? (json?["sessionId"] as? String)
    }

    public static func windowSize(_ json: [String: Any]?) -> CGSize? {
        let v = (json?["value"] as? [String: Any]) ?? json ?? [:]
        guard let w = (v["width"] as? NSNumber)?.doubleValue,
              let h = (v["height"] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: w, height: h)
    }

    public static func ready(_ json: [String: Any]?) -> Bool {
        ((json?["value"] as? [String: Any])?["ready"] as? Bool) ?? false
    }

    /// The session WDA is already serving, from `/status`'s top-level
    /// `sessionId`. WDA allows one session per phone and creating one silently
    /// kills the old — so the app joins an agent's session instead of making
    /// its own and yanking it out from under the MCP server.
    public static func activeSessionId(_ statusJSON: [String: Any]?) -> String? {
        guard let id = statusJSON?["sessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
