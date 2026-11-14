// SimulatorManager — runs WebDriverAgent on every enabled iOS Simulator at once.
//
// The enabled set is one UserDefaults array (iMirrorCore `enabledSimulatorsKey`,
// "imirror.enabledSimulators" in com.local.imirror). It is the only switch:
// Settings writes it, so does `defaults write` / scripts/imirror-sim.sh, and
// this type polls it every 2 s and starts or stops controllers to match. A
// relaunch re-reads it, so enabled sims come back on their own.
//
// Each sim gets a sticky port slot and alias (iMirrorCore/SimSlots), persisted
// like the phones' slots, and is published to the device file through
// ChainManager.simulatorEntries.
//
// Main thread only.

import Foundation
import iMirrorCore

final class SimulatorManager {
    struct Row {
        let udid: String
        let alias: String
        let slot: SimSlot
        let device: SimDevice?
        let phase: SimPhase?
    }

    /// Anything shown in Settings changed (a phase, the enabled set, a problem).
    var onChange: (() -> Void)?
    /// The device-file entries changed.
    var onEntries: (([RegisteredDevice]) -> Void)?
    /// Names phones already go by, so a sim never takes one.
    var phoneAliases: () -> Set<String> = { [] }

    private(set) var enabled: [String] = []
    /// Enabled sims that could not be started, and why.
    private(set) var problems: [String: String] = [:]
    /// Last `simctl list`, by UDID.
    private(set) var known: [String: SimDevice] = [:]
    private(set) var knownList: [SimDevice] = []
    private(set) var xcodeAvailable: Bool?

    private var controllers: [String: SimulatorController] = [:]
    private var phases: [String: SimPhase] = [:]
    private var table: SimSlotTable
    private var timer: Timer?
    private var listing = false
    private var listedAt: TimeInterval?
    private var running = false

    private static let tableKey = "imirror.simulatorSlots"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.tableKey),
           let saved = try? JSONDecoder().decode(SimSlotTable.self, from: data) {
            table = saved
        } else {
            table = SimSlotTable()
        }
    }

    // MARK: Start / stop

    func start() {
        guard !running else { return }
        running = true
        refreshList()
        reconcile()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// App quit: stop every runner now. The enabled set is kept, so the next
    /// launch brings the same sims back.
    func stopAll() {
        running = false
        timer?.invalidate(); timer = nil
        for c in controllers.values { c.stopNow() }
        controllers = [:]
        phases = [:]
    }

    // MARK: The switch

    func isEnabled(_ udid: String) -> Bool { enabled.contains(udid.uppercased()) }

    /// Add or remove `udid` from the enabled set. Takes effect at once (and
    /// would anyway, on the next poll).
    func setEnabled(_ udid: String, _ on: Bool) {
        var list = normalizeEnabledSimulators(UserDefaults.standard.object(forKey: enabledSimulatorsKey))
        let u = udid.uppercased()
        if on { if !list.contains(u) { list.append(u) } } else { list.removeAll { $0 == u } }
        UserDefaults.standard.set(list, forKey: enabledSimulatorsKey)
        reconcile()
    }

    /// Re-run `simctl list` (off main); the picker and unknown UDIDs use it.
    func refreshList(then done: (() -> Void)? = nil) {
        guard !listing else { return }
        listing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasXcode = SimulatorController.xcodeAvailable()
            let sims = hasXcode ? SimulatorController.listSimulators() : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.listing = false
                self.listedAt = ProcessInfo.processInfo.systemUptime
                self.xcodeAvailable = hasXcode
                self.knownList = sims
                self.known = Dictionary(sims.map { ($0.udid.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
                self.reconcile()
                self.onChange?()
                done?()
            }
        }
    }

    // MARK: Rows for Settings

    var rows: [Row] {
        enabled.compactMap { udid in
            guard let e = table.entries[udid] else { return nil }
            return Row(udid: udid, alias: e.alias, slot: SimSlot(e.index),
                       device: known[udid], phase: phases[udid])
        }
    }

    func phase(_ udid: String) -> SimPhase? { phases[udid.uppercased()] }

    func alias(_ udid: String) -> String? { table.entries[udid.uppercased()]?.alias }

    /// Every alias a sim has ever had — phones mustn't be renamed onto one.
    var allAliases: Set<String> { Set(table.entries.values.map { $0.alias.lowercased() }) }

    // MARK: Reconcile

    private func reconcile() {
        guard running else { return }
        let wanted = normalizeEnabledSimulators(UserDefaults.standard.object(forKey: enabledSimulatorsKey))
        var changed = wanted != enabled
        enabled = wanted
        let wantedSet = Set(wanted)

        for (udid, c) in controllers where !wantedSet.contains(udid) {
            NSLog("iMirror: simulator \(udid) disabled — stopping its WebDriverAgent")
            c.disable()
            controllers[udid] = nil
            phases[udid] = nil
            changed = true
        }
        for udid in problems.keys where !wantedSet.contains(udid) {
            problems[udid] = nil
            changed = true
        }

        var unknown = false
        for udid in wanted where controllers[udid] == nil {
            guard xcodeAvailable == true else {
                if xcodeAvailable == false, problems[udid] != "requires Xcode" {
                    problems[udid] = "requires Xcode"; changed = true
                }
                continue
            }
            guard let device = known[udid] else {
                unknown = true
                let why = "no available simulator has this UDID (xcrun simctl list devices available)"
                if listedAt != nil, problems[udid] != why { problems[udid] = why; changed = true }
                continue
            }
            let inUse = Set(controllers.keys.compactMap { table.entries[$0]?.index })
            let result = assignSimSlot(udid: udid, name: device.name, table: &table, inUse: inUse,
                                       otherAliases: phoneAliases(), isPortFree: ChainManager.portIsFree,
                                       now: Date())
            saveTable()
            switch result {
            case .assigned(let slot, let alias, _):
                problems[udid] = nil
                NSLog("iMirror: simulator \(alias) (\(udid)) enabled — WDA on :\(slot.wdaPort)")
                let c = SimulatorController(udid: udid, slot: slot)
                c.onPhase = { [weak self, weak c] p in
                    guard let self, let c, self.controllers[udid] === c else { return }
                    self.phases[udid] = p
                    self.publish()
                    self.onChange?()
                }
                controllers[udid] = c
                phases[udid] = .booting
                c.enable()
                changed = true
            case .full:
                let why = "all \(SimSlot.maxSims) simulator ports belong to enabled simulators"
                if problems[udid] != why { problems[udid] = why; changed = true }
            }
        }
        // A UDID simctl didn't list: maybe the sim was just created. Look again,
        // but not on every 2 s tick.
        if unknown, !listing,
           (listedAt.map { ProcessInfo.processInfo.systemUptime - $0 > 20 } ?? true) {
            refreshList()
        }
        if changed {
            publish()
            onChange?()
        }
    }

    private func publish() {
        let entries: [RegisteredDevice] = enabled.compactMap { udid in
            guard controllers[udid] != nil, let e = table.entries[udid], let phase = phases[udid] else { return nil }
            let d = known[udid]
            return simRegistryEntry(udid: udid, alias: e.alias, name: d?.name, runtime: d?.runtime,
                                    slot: SimSlot(e.index), phase: phase)
        }
        onEntries?(entries)
    }

    private func saveTable() {
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: Self.tableKey)
        }
    }
}
