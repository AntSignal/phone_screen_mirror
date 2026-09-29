import Foundation

// Which loopback ports each phone's chain uses, and which short name (alias)
// agents call it by. Pure, so the stickiness rules are unit-tested.

/// A block of three loopback ports for one phone: the in-app relay the app and
/// MCP talk to, the go-ios `forward` behind it, and the MJPEG forward.
///
/// Slot 0 is exactly the single-phone layout (relay 8100, forward 8101, MJPEG
/// 9110), so everything that hard-codes :8100 keeps driving the first phone.
/// Each further slot adds 10.
public struct PortSlot: Equatable, Hashable, Sendable {
    /// Slot 10 would put a forward on 8201, the Simulator's WDA port.
    public static let maxSlots = 8

    public let index: Int

    public init(_ index: Int) { self.index = index }

    public var relayPort: UInt16 { UInt16(8100 + 10 * index) }
    public var forwardPort: UInt16 { UInt16(8101 + 10 * index) }
    public var mjpegPort: UInt16 { UInt16(9110 + 10 * index) }
    public var ports: [UInt16] { [relayPort, forwardPort, mjpegPort] }
    public var relayURL: String { "http://127.0.0.1:\(relayPort)" }
}

/// Every phone the app has ever run, by UDID: its slot and alias. Persisted, so
/// a phone keeps its ports and name across unplugging and app restarts — scripts
/// and agents can hard-code "phone2 is :8110".
public struct SlotTable: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var slot: Int
        public var alias: String
        public var lastSeen: Date?

        public init(slot: Int, alias: String, lastSeen: Date? = nil) {
            self.slot = slot; self.alias = alias; self.lastSeen = lastSeen
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public func udid(forAlias alias: String) -> String? {
        entries.first { $0.value.alias.lowercased() == alias.lowercased() }?.key
    }
}

public enum SlotAssignment: Equatable, Sendable {
    case assigned(slot: PortSlot, alias: String, isNew: Bool)
    /// The phone's own slot has a port something else is holding. The phone is
    /// not moved: clients may have its ports written down.
    case conflict(slot: PortSlot, port: UInt16)
    /// All slots belong to phones that are attached right now.
    case full
}

/// The default name for a slot's phone: phone1, phone2, …
public func defaultAlias(slot: Int) -> String { "phone\(slot + 1)" }

/// Give `udid` its slot, creating an entry for a phone seen for the first time.
///
/// - A known phone keeps its slot, if that slot's ports are free.
/// - A new phone gets the lowest slot no entry has ever held whose ports are
///   free. Only when every slot has an owner does it take the slot of the
///   longest-absent phone, which then gets a new one when it returns.
///
/// `inUse` are slots of phones attached right now (never taken from them);
/// `isPortFree` asks the OS whether a port can be bound.
public func assignSlot(udid: String, table: inout SlotTable, inUse: Set<Int>,
                       isPortFree: (UInt16) -> Bool, now: Date,
                       maxSlots: Int = PortSlot.maxSlots) -> SlotAssignment {
    if var entry = table.entries[udid] {
        let slot = PortSlot(entry.slot)
        if let busy = slot.ports.first(where: { !isPortFree($0) }) {
            return .conflict(slot: slot, port: busy)
        }
        entry.lastSeen = now
        table.entries[udid] = entry
        return .assigned(slot: slot, alias: entry.alias, isNew: false)
    }
    let owned = Set(table.entries.values.map(\.slot))
    let fresh = (0..<maxSlots).first { i in
        !owned.contains(i) && !inUse.contains(i) && PortSlot(i).ports.allSatisfy(isPortFree)
    }
    var chosen = fresh
    if chosen == nil {
        // Reclaim from the phone that has been gone longest (never-seen first).
        let absent = table.entries
            .filter { !inUse.contains($0.value.slot) && PortSlot($0.value.slot).ports.allSatisfy(isPortFree) }
            .sorted { ($0.value.lastSeen ?? .distantPast) < ($1.value.lastSeen ?? .distantPast) }
        if let victim = absent.first {
            chosen = victim.value.slot
            table.entries[victim.key] = nil
        }
    }
    guard let index = chosen else { return .full }
    let alias = uniqueAlias(defaultAlias(slot: index), in: table)
    table.entries[udid] = SlotTable.Entry(slot: index, alias: alias, lastSeen: now)
    return .assigned(slot: PortSlot(index), alias: alias, isNew: true)
}

/// `base` unless another phone already goes by it (a user may have renamed a
/// phone to "phone2"), then base-2, base-3, …
private func uniqueAlias(_ base: String, in table: SlotTable) -> String {
    let taken = Set(table.entries.values.map { $0.alias.lowercased() })
    if !taken.contains(base.lowercased()) { return base }
    var n = 2
    while taken.contains("\(base)-\(n)".lowercased()) { n += 1 }
    return "\(base)-\(n)"
}

public enum AliasProblem: Equatable, Sendable {
    case badFormat
    case looksLikeUDID
    case taken(byUDID: String)
}

/// Why `alias` can't name `udid`'s phone, or nil if it can. Aliases are what
/// agents type as `device=`, so they are short, lower-case, start with a
/// letter, and can't be all hex (it would read as a UDID fragment).
public func validateAlias(_ alias: String, forUDID udid: String, in table: SlotTable) -> AliasProblem? {
    let pattern = "^[a-z][a-z0-9_-]{0,23}$"
    guard alias.range(of: pattern, options: .regularExpression) != nil else { return .badFormat }
    let hex = CharacterSet(charactersIn: "0123456789abcdef-")
    if alias.count >= 4, alias.unicodeScalars.allSatisfy({ hex.contains($0) }) { return .looksLikeUDID }
    if let owner = table.udid(forAlias: alias), owner != udid { return .taken(byUDID: owner) }
    return nil
}
