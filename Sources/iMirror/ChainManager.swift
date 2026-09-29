// ChainManager — finds the phones, gives each a chain, and tells the MCP server.
//
// Polls `ios list --details` every 3s. A new USB phone gets its sticky port
// slot (iMirrorCore/PortSlots) and a DeviceController; a phone missing from two
// polls in a row is torn down but keeps its slot and alias for next time. The
// Mac's one go-ios tunnel is owned here, because restarting it drops every
// phone — so requests to restart it are rate-limited across phones.
//
// Everything a client needs to drive the phones is published to the device
// file (DeviceRegistryWriter), which mcp-server/imirror_mcp.py reads.
//
// Main thread only.

import Darwin
import Foundation
import iMirrorCore

final class ChainManager {
    private let bin: URL?
    private let workDir: URL
    private let tunnel: TunnelSupervisor?
    private let registry = DeviceRegistryWriter()

    /// Attached phones with a chain, by slot.
    private(set) var controllers: [DeviceController] = []
    /// Attached phones that could NOT get a chain, and why (a port in use…).
    private(set) var problems: [String: String] = [:]
    private(set) var running = false
    /// UDIDs the shared tunnel had a route to at the last poll.
    private(set) var tunnelUDIDs: Set<String> = []

    private var table: SlotTable
    private var missingPolls: [String: Int] = [:]
    private var pollTimer: Timer?
    private var polling = false
    private var lastTunnelRestart: TimeInterval?
    private var writeScheduled = false

    /// The Simulator, when Settings has one enabled; listed in the device file.
    var simulatorEntry: RegisteredDevice? { didSet { if simulatorEntry != oldValue { scheduleWrite() } } }

    /// The set of phones (or their order/aliases/problems) changed.
    var onDevicesChanged: (() -> Void)?
    var onControllerChange: ((DeviceController) -> Void)?
    var onControllerHealth: ((DeviceController, DeviceController.Health, DeviceController.Health) -> Void)?
    var onControllerStatus: ((DeviceController, String) -> Void)?
    /// Automation can't start (another iMirror owns the phones).
    var onBlocked: ((String) -> Void)?

    private static let slotsKey = "imirror.deviceSlots"

    init() {
        bin = locateGoIOS()
        // Writable working dir for go-ios (selfIdentity.plist, pair records).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("iMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        workDir = support
        tunnel = bin.map { TunnelSupervisor(bin: $0, workDir: support) }
        if let data = UserDefaults.standard.data(forKey: Self.slotsKey),
           let saved = try? JSONDecoder().decode(SlotTable.self, from: data) {
            table = saved
        } else {
            table = SlotTable()
        }
    }

    /// True if the go-ios binary was found, so the app runs WDA itself. If
    /// false, WDA must be brought up externally (scripts/wda-up.sh) on :8100.
    var canSelfManage: Bool { bin != nil }

    var goiosPath: String? { bin?.path }

    func controller(_ udid: String?) -> DeviceController? {
        guard let udid else { return nil }
        return controllers.first { $0.udid == udid }
    }

    // MARK: Start / stop

    func start() {
        guard !running else { return }
        if let pid = registry.foreignOwner() {
            onBlocked?("Another iMirror (pid \(pid)) is already running the phones — quit it first.")
            return
        }
        running = true
        guard let bin else {
            // No go-ios: probe an externally started WDA on :8100 as one phone.
            let external = AttachedDevice(udid: "external", productType: nil, productVersion: nil, connection: "")
            add(makeController(external, slot: PortSlot(0), alias: "phone1", chain: nil))
            onDevicesChanged?()
            return
        }
        // Clear go-ios orphans a crashed instance left behind (often a tunnel
        // still holding :60105) before this app owns any child — off main,
        // since it runs three pkills.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for pattern in GoIOS.sweepAllPatterns(bin: bin.path) { GoIOS.pkill(pattern) }
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.tunnel?.start()
                self.poll()
                let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
                RunLoop.main.add(t, forMode: .common)
                self.pollTimer = t
            }
        }
        scheduleWrite()
    }

    func stop() {
        guard running else { return }
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
        for c in controllers { c.stop() }
        controllers = []
        problems = [:]
        missingPolls = [:]
        tunnel?.stop()
        registry.remove()
        onDevicesChanged?()
    }

    // MARK: Discovery

    private func poll() {
        guard running, !polling, let bin, let tunnel else { return }
        polling = true
        let workDir = self.workDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listed = GoIOS.run(bin, GoIOS.listArgs, workDir: workDir)
            let attached = GoIOSParsing.attachedDevices(fromListDetails: listed.out)
            let tunneled = tunnel.tunneledUDIDs()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                guard self.running else { return }
                self.tunnelUDIDs = tunneled
                // A failed `ios list` says nothing about what's attached: never
                // tear a phone down on it.
                if listed.status == 0 { self.reconcile(attached.filter(\.isUSB)) }
            }
        }
    }

    private func reconcile(_ usb: [AttachedDevice]) {
        var changed = false
        let present = Dictionary(usb.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })

        // Gone phones: two misses in a row, so one flaky poll doesn't bounce a chain.
        for c in controllers where present[c.udid] == nil {
            missingPolls[c.udid, default: 0] += 1
            if missingPolls[c.udid, default: 0] >= 2 {
                NSLog("iMirror: \(c.alias) (\(c.udid)) detached — stopping its chain")
                c.stop()
                controllers.removeAll { $0 === c }
                missingPolls[c.udid] = nil
                changed = true
            }
        }
        // go-ios's order, not the dictionary's: two new phones in one poll get
        // their slots in a repeatable order.
        for device in usb where present[device.udid] == device {
            let udid = device.udid
            missingPolls[udid] = nil
            if let c = controller(udid) {
                c.attached = device                   // e.g. an iOS update
                continue
            }
            // New (or still-blocked) phone: try to give it its slot.
            let inUse = Set(controllers.map { $0.slot.index })
            let result = assignSlot(udid: udid, table: &table, inUse: inUse,
                                    isPortFree: ChainManager.portIsFree, now: Date())
            saveTable()
            switch result {
            case .assigned(let slot, let alias, _):
                problems[udid] = nil
                guard let bin else { continue }
                let chain = DeviceChain(udid: udid, slot: slot, bin: bin, workDir: workDir)
                if let tunnel {
                    chain.tunnelHasDevice = { tunnel.tunneledUDIDs().contains(udid) }
                }
                NSLog("iMirror: \(alias) (\(udid)) attached — slot \(slot.index), WDA on :\(slot.relayPort)")
                add(makeController(device, slot: slot, alias: alias, chain: chain))
                changed = true
            case .conflict(let slot, let port):
                let why = "port \(port) (its slot \(slot.index)) is held by another process"
                if problems[udid] != why { problems[udid] = why; changed = true }
            case .full:
                let why = "all \(PortSlot.maxSlots) port slots belong to attached phones"
                if problems[udid] != why { problems[udid] = why; changed = true }
            }
        }
        let stale = problems.keys.filter { present[$0] == nil }
        if !stale.isEmpty { stale.forEach { problems[$0] = nil }; changed = true }
        if changed {
            onDevicesChanged?()
            scheduleWrite()
        }
    }

    private func makeController(_ device: AttachedDevice, slot: PortSlot, alias: String,
                                chain: DeviceChain?) -> DeviceController {
        let c = DeviceController(udid: device.udid, slot: slot, alias: alias, attached: device, chain: chain)
        c.othersHealthy = { [weak self, weak c] in
            self?.controllers.contains { $0 !== c && $0.health == .connected } ?? false
        }
        c.tunnelHasDevice = { [weak self] in self?.tunnelUDIDs.contains(device.udid) ?? false }
        c.requestTunnelRestart = { [weak self] in self?.requestTunnelRestart(coalesce: true) }
        c.onChange = { [weak self, weak c] in
            guard let self, let c else { return }
            self.scheduleWrite()
            self.onControllerChange?(c)
        }
        c.onHealth = { [weak self, weak c] old, new in
            guard let self, let c else { return }
            self.onControllerHealth?(c, old, new)
        }
        c.onStatus = { [weak self, weak c] text in
            guard let self, let c else { return }
            self.onControllerStatus?(c, text)
        }
        return c
    }

    private func add(_ c: DeviceController) {
        controllers.append(c)
        controllers.sort { $0.slot.index < $1.slot.index }
        // Stagger probes so several phones' 3s ticks don't coincide.
        c.start(stagger: 0.4 * Double(c.slot.index % 7))
    }

    // MARK: The shared tunnel

    /// Restart the tunnel and, with it, every phone's chain. From a phone's
    /// ladder this is rate-limited: two phones reaching their grace together
    /// would otherwise knock each other's fresh chains down again. A request
    /// inside the cooldown restarts only that phone's chain.
    func requestTunnelRestart(coalesce: Bool) {
        guard running, let tunnel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if coalesce, !shouldRestartTunnel(lastAt: lastTunnelRestart, now: now) {
            NSLog("iMirror: tunnel restarted \(Int(now - (lastTunnelRestart ?? now)))s ago — not again yet")
            return
        }
        lastTunnelRestart = now
        NSLog("iMirror: restarting the USB tunnel and every phone's chain")
        for c in controllers { c.chain?.stopChildren() }
        tunnel.restart { [weak self] in
            guard let self, self.running else { return }
            for c in self.controllers {
                c.tunnelRestarted()
                c.chain?.start()
            }
        }
    }

    // MARK: Aliases

    /// Rename a phone. The name is what agents pass as `device=`, so it must
    /// be unique and look nothing like a UDID (see validateAlias).
    func rename(_ c: DeviceController, to alias: String) -> AliasProblem? {
        if let problem = validateAlias(alias, forUDID: c.udid, in: table) { return problem }
        table.entries[c.udid]?.alias = alias
        saveTable()
        c.alias = alias
        onDevicesChanged?()
        scheduleWrite()
        return nil
    }

    private func saveTable() {
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: Self.slotsKey)
        }
    }

    // MARK: Device file

    /// Coalesce bursts (every probe of every phone can report a change).
    private func scheduleWrite() {
        guard running, canSelfManage, !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.writeScheduled = false
            guard self.running else { return }
            self.registry.write(self.snapshot())
        }
    }

    private func snapshot() -> DeviceRegistryFile {
        var devices = controllers.map { c in
            RegisteredDevice(udid: c.udid, alias: c.alias, kind: .device,
                             productType: c.attached.productType, iosVersion: c.attached.productVersion,
                             connection: c.attached.connection, slot: c.slot.index,
                             wdaURL: c.slot.relayURL, mjpegPort: Int(c.slot.mjpegPort),
                             state: c.registryState, detail: c.detail)
        }
        if let sim = simulatorEntry { devices.append(sim) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return DeviceRegistryFile(ownerPid: getpid(), appVersion: version,
                                  updatedAt: DeviceRegistryCodec.timestamp(Date()),
                                  goios: bin?.path, devices: devices)
    }

    // MARK: Ports

    /// True if nothing accepts connections on loopback `port` (v4 or v6). A
    /// connect test rather than a bind test: bind trips over TIME_WAIT leftovers,
    /// and a dual-stack wildcard listener (e.g. iproxy on *:8101) would let an
    /// IPv4-only bind succeed while go-ios's own listen then fails.
    static func portIsFree(_ port: UInt16) -> Bool {
        !acceptsConnection(family: AF_INET, port: port) && !acceptsConnection(family: AF_INET6, port: port)
    }

    private static func acceptsConnection(family: Int32, port: UInt16) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        var addr6 = sockaddr_in6()
        addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = port.bigEndian
        addr6.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &addr6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}

// MARK: - The device file

/// Writes ~/Library/Application Support/iMirror/devices.json (or
/// $IMIRROR_DEVICES_FILE) — see iMirrorCore/DeviceRegistry for the format.
final class DeviceRegistryWriter {
    let url: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["IMIRROR_DEVICES_FILE"], !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("iMirror/devices.json")
        }
    }

    /// Atomic (write-then-rename), so a reader never sees half a file.
    func write(_ file: DeviceRegistryFile) {
        do {
            let data = try DeviceRegistryCodec.encode(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("iMirror: writing \(url.path) failed: \(error.localizedDescription)")
        }
    }

    /// Delete the file if this process wrote it (never another live instance's).
    func remove() {
        guard let data = try? Data(contentsOf: url),
              let file = try? DeviceRegistryCodec.decode(data),
              file.ownerPid == getpid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The pid of ANOTHER live iMirror that owns the file, if any.
    func foreignOwner() -> Int32? {
        guard let data = try? Data(contentsOf: url),
              let file = try? DeviceRegistryCodec.decode(data),
              file.ownerPid != getpid(), file.ownerPid > 0,
              kill(file.ownerPid, 0) == 0 else { return nil }
        return file.ownerPid
    }
}
