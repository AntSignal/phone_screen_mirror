import Foundation

// Several Simulators at once: which loopback ports each one's WebDriverAgent
// uses, and which name agents call it by. Pure, so the stickiness rules are
// unit-tested; SimulatorManager in the app does the shelling-out.
//
// Sims share the Mac's loopback, so every WDA on every sim needs its own HTTP
// port AND its own MJPEG port (WDA binds 9100 by default; a second sim's WDA
// would lose that bind). Phones live on 8100+10n / 8101+10n / 9110+10n for
// n < PortSlot.maxSlots, so sims start at 8201 / 9201 and never meet them.

/// One Simulator's ports. Index 1 is :8201 — the port the single-sim app used,
/// and that the pinned `imirror-sim` MCP registration still points at.
public struct SimSlot: Equatable, Hashable, Sendable {
    public static let maxSims = 8

    public let index: Int

    public init(_ index: Int) { self.index = index }

    public var wdaPort: UInt16 { UInt16(8200 + index) }
    public var mjpegPort: UInt16 { UInt16(9200 + index) }
    public var ports: [UInt16] { [wdaPort, mjpegPort] }
    public var wdaURL: String { "http://127.0.0.1:\(wdaPort)" }
}

/// Every Simulator the app has ever enabled, by UDID: its port index and alias.
/// Persisted, so a sim keeps its port and name across disabling and relaunches.
public struct SimSlotTable: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var index: Int
        public var alias: String
        public var lastSeen: Date?

        public init(index: Int, alias: String, lastSeen: Date? = nil) {
            self.index = index; self.alias = alias; self.lastSeen = lastSeen
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public func udid(forAlias alias: String) -> String? {
        entries.first { $0.value.alias.lowercased() == alias.lowercased() }?.key
    }
}

public enum SimSlotAssignment: Equatable, Sendable {
    case assigned(slot: SimSlot, alias: String, isNew: Bool)
    /// Every index belongs to a sim that is enabled right now.
    case full
}

/// Give `udid` its sim slot, creating an entry the first time a sim is enabled.
///
/// - A known sim keeps its index even if its port answers: that is almost
///   always its own WDA left running by a previous app run, which the new
///   runner replaces.
/// - A new sim gets the lowest index no entry has held whose ports are free;
///   failing that, the index of the longest-unused sim not enabled now.
///
/// `inUse`: indexes of sims enabled right now. `otherAliases`: names taken
/// outside this table (the phones'), compared case-insensitively.
public func assignSimSlot(udid: String, name: String, table: inout SimSlotTable,
                          inUse: Set<Int>, otherAliases: Set<String>,
                          isPortFree: (UInt16) -> Bool, now: Date,
                          maxSims: Int = SimSlot.maxSims) -> SimSlotAssignment {
    if var entry = table.entries[udid] {
        entry.lastSeen = now
        table.entries[udid] = entry
        return .assigned(slot: SimSlot(entry.index), alias: entry.alias, isNew: false)
    }
    let owned = Set(table.entries.values.map(\.index))
    var chosen = (1...maxSims).first { i in
        !owned.contains(i) && !inUse.contains(i) && SimSlot(i).ports.allSatisfy(isPortFree)
    }
    if chosen == nil {
        let absent = table.entries
            .filter { !inUse.contains($0.value.index) }
            .sorted { ($0.value.lastSeen ?? .distantPast) < ($1.value.lastSeen ?? .distantPast) }
        if let victim = absent.first {
            chosen = victim.value.index
            table.entries[victim.key] = nil
        }
    }
    guard let index = chosen else { return .full }
    var taken = Set(otherAliases.map { $0.lowercased() })
    taken.formUnion(table.entries.values.map { $0.alias.lowercased() })
    let alias = simAlias(name: name, index: index, taken: taken)
    table.entries[udid] = SimSlotTable.Entry(index: index, alias: alias, lastSeen: now)
    return .assigned(slot: SimSlot(index), alias: alias, isNew: true)
}

/// The name agents pass as `device=` for a sim: its Simulator name, slugified
/// ("iPhone 17 Pro" → "iphone-17-pro"), made unique with -2, -3…; or simN when
/// the name gives nothing usable. Always passes `validateAlias`'s format rules.
/// `taken` must be lower-case.
public func simAlias(name: String, index: Int, taken: Set<String>) -> String {
    let fallback = "sim\(index)"
    guard let base = slugifySimName(name) else {
        return uniquify(fallback, taken: taken)
    }
    return uniquify(base, taken: taken)
}

/// `base`, or base-2, base-3, … — trimmed so the result stays within 24 chars.
private func uniquify(_ base: String, taken: Set<String>) -> String {
    if !taken.contains(base) { return base }
    var n = 2
    while true {
        let suffix = "-\(n)"
        var head = String(base.prefix(24 - suffix.count))
        while head.hasSuffix("-") || head.hasSuffix("_") { head.removeLast() }
        let candidate = head + suffix
        if !taken.contains(candidate) { return candidate }
        n += 1
    }
}

/// Lower-case, runs of anything else collapsed to "-", at most 24 chars, must
/// start with a letter. nil when that leaves nothing usable: empty, all-hex
/// (it would read as a UDID fragment), or "phoneN" (the phones' own names).
public func slugifySimName(_ name: String) -> String? {
    var out = ""
    var pendingDash = false
    for ch in name.lowercased().unicodeScalars {
        let isAlnum = ("a"..."z").contains(ch) || ("0"..."9").contains(ch)
        if isAlnum {
            if pendingDash && !out.isEmpty { out.append("-") }
            pendingDash = false
            out.unicodeScalars.append(ch)
        } else {
            pendingDash = true
        }
    }
    // Drop leading digits/dashes until a letter leads.
    while let first = out.unicodeScalars.first, !("a"..."z").contains(first) { out.removeFirst() }
    out = String(out.prefix(24))
    while out.hasSuffix("-") { out.removeLast() }
    guard !out.isEmpty else { return nil }
    if out.range(of: "^phone[0-9]+$", options: .regularExpression) != nil { return nil }
    let hex = CharacterSet(charactersIn: "0123456789abcdef-")
    if out.count >= 4, out.unicodeScalars.allSatisfy({ hex.contains($0) }) { return nil }
    return out
}

// MARK: - The enabled list

/// The UserDefaults key (bundle com.local.imirror) holding the UDIDs of the
/// Simulators to run WDA on. The app reads it on launch and watches it live,
/// so `defaults write com.local.imirror imirror.enabledSimulators -array …`
/// works with no GUI.
public let enabledSimulatorsKey = "imirror.enabledSimulators"

/// The enabled list as the app acts on it: a defaults value of any shape in,
/// upper-cased simulator UDIDs out, first occurrence wins. A lone string is
/// accepted too (`defaults write … -string <udid>` is an easy slip).
public func normalizeEnabledSimulators(_ raw: Any?) -> [String] {
    let items: [Any]
    if let a = raw as? [Any] { items = a } else if let s = raw as? String { items = [s] } else { return [] }
    var seen = Set<String>()
    var out: [String] = []
    for case let s as String in items {
        let u = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard isSimulatorUDID(u), seen.insert(u).inserted else { continue }
        out.append(u)
    }
    return out
}

/// CoreSimulator UDIDs are RFC 4122 UUIDs: 8-4-4-4-12 hex.
public func isSimulatorUDID(_ s: String) -> Bool {
    s.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
            options: .regularExpression) != nil
}

// MARK: - The device file

/// Where a sim's WDA is in coming up, as the device file says it.
public enum SimPhase: Equatable, Sendable {
    case booting, building, starting, ready
    /// WDA was up and stopped answering; its runner is being relaunched.
    case restarting
    case failed(String)
}

/// A sim's entry in devices.json.
public func simRegistryEntry(udid: String, alias: String, name: String?, runtime: String?,
                             slot: SimSlot, phase: SimPhase) -> RegisteredDevice {
    let state: RegisteredDevice.State
    var detail: String?
    switch phase {
    case .booting: state = .starting; detail = "booting the simulator"
    case .building: state = .starting; detail = "building WebDriverAgent"
    case .starting: state = .starting; detail = "waiting for WebDriverAgent"
    case .restarting: state = .starting; detail = "WebDriverAgent stopped answering; relaunching it"
    case .ready: state = .ready
    case .failed(let why): state = .failed; detail = why
    }
    // "iOS 26.5" → "26.5"
    let version = runtime?.split(separator: " ").last.map(String.init)
    return RegisteredDevice(udid: udid, alias: alias, kind: .simulator, productType: name,
                            iosVersion: version, wdaURL: slot.wdaURL, state: state, detail: detail)
}
