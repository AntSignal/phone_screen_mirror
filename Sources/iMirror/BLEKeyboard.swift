// BLEKeyboard — iMirror as a Bluetooth LE keyboard (HID over GATT), to type
// where WDA cannot: the lock screen and the "Enable UI Automation" sheet.
// macOS is always the classic HID host, so iPhones are reached only through
// a CoreBluetooth peripheral with HOGP services. Bytes live in iMirrorCore.
// - SIG UUIDs as full 128-bit strings; the 16-bit form is refused.
// - No .extendedProperties: its descriptor breaks HID binding.
// - Send a key-up report on subscribe, or some hosts stall.
// - Every value needs encryption, so phones must bond.
// Reports may spell a passcode: log counts. Main thread only.

import CoreBluetooth
import Foundation
import iMirrorCore

enum BLEKeyboardError: Error, Equatable {
    /// Bluetooth is off, unsupported, or iMirror was refused access.
    case bluetoothUnavailable(String)
    case serviceSetupFailed
    /// The target phone did not connect and subscribe in time.
    case notConnected
    /// The phone stopped taking reports mid-way.
    case sendFailed
    /// Another pairing or typing run is still going.
    case busy
    /// The check before the first key said no; nothing was sent.
    case stale
}

/// One-shot wake-up for a suspended task. Main queue only.
private final class Waiter: @unchecked Sendable {
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
    func fire(_ value: Bool) { cont?.resume(returning: value); cont = nil }
}

@MainActor
final class BLEKeyboard: NSObject {
    static let pairingSettleSec: TimeInterval = 5
    static let sendTimeoutSec: TimeInterval = 2
    /// Subscribe-to-first-key pause; a lost first digit costs an attempt.
    static let linkSettleSec: TimeInterval = 1

    /// "180A" → the full SIG base UUID. See the platform rules above.
    nonisolated static func sig(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    let pairsFile: KeyboardPairsFile
    // Made lazily: making it shows the Bluetooth prompt.
    private var manager: CBPeripheralManager?
    private var running = false
    // stop() bumps it, ending any pairing or connect wait.
    private var stopEpoch = 0
    private var servicesAdded = false
    private var addFailed = false

    // Phones subscribed to each input characteristic, by central id.
    private var reportSubs: [UUID: CBCentral] = [:]
    private var bootSubs: [UUID: CBCentral] = [:]
    // When each central first subscribed, for linkSettleSec.
    private var subscribedAt: [UUID: Date] = [:]
    private var subscriptionLog: [(central: String, at: Date)] = []
    private var protocolMode = HIDKeyboard.reportProtocol
    private var leds: UInt8 = 0

    private var stateWaiters: [Waiter] = []
    private var addWaiters: [Waiter] = []
    private var subscribeWaiters: [Waiter] = []
    private var readyWaiters: [Waiter] = []

    private var chars = Chars()
    // Centrals subscribed at the last link report.
    private var linked: Set<UUID> = []

    /// A phone's keyboard link came up (true) or down.
    var onLinkChange: ((UUID, Bool) -> Void)?

    init(pairsURL: URL = KeyboardPairsFile.defaultURL) {
        pairsFile = KeyboardPairsFile(url: pairsURL)
        super.init()
    }

    // MARK: - API

    /// Advertises for `window` seconds and ties the one new phone that
    /// subscribes to `udid`. Ends early once a single candidate has been
    /// alone for a few seconds. Leaves the services up for a test.
    func startPairing(udid: String, window: TimeInterval) async throws -> PairingOutcome {
        guard !running else { throw BLEKeyboardError.busy }
        running = true
        defer { running = false }
        try await ensureServices()
        let now = Date()
        let win = PairingWindow(udid: udid, opensAt: now, closesAt: now.addingTimeInterval(window),
                                subscribedBefore: Set(allSubscribed().keys.map(\.uuidString)))
        startAdvertising()
        defer { manager?.stopAdvertising() }
        var pairs = loadPairs()
        var candidateSince: Date?
        let epoch = stopEpoch
        while Date() < win.closesAt, epoch == stopEpoch {
            let outcome = PairingRule.decide(window: win, subscriptions: subscriptionLog, pairs: pairs)
            if case .paired = outcome {
                let since = candidateSince ?? Date()
                candidateSince = since
                if Date().timeIntervalSince(since) >= Self.pairingSettleSec { break }
            } else {
                candidateSince = nil
            }
            _ = await wait(seconds: 0.5) { subscribeWaiters.append($0) }
        }
        let outcome = PairingRule.decide(window: win, subscriptions: subscriptionLog, pairs: pairs)
        if case .paired(let central) = outcome {
            pairs.record(udid: udid, central: central, at: Date())
            savePairs(pairs)
        }
        NSLog("iMirror: keyboard pairing for \(udid) ended: \(Self.describe(outcome))")
        return outcome
    }

    /// Sends `reports` to one phone only, waiting for it to connect first.
    /// `beforeFirstKey` runs after the connect wait and settle, so a
    /// caller's freshness rule covers the real first key.
    /// Never logs the reports: they may spell a passcode.
    func type(reports: [KeyStep], to central: UUID, connectTimeout: TimeInterval = 15,
              beforeFirstKey: FirstKeyCheck? = nil) async throws {
        guard !running else { throw BLEKeyboardError.busy }
        running = true
        defer { running = false }
        try await ensureServices()
        if allSubscribed()[central] == nil {
            startAdvertising()
            let deadline = Date().addingTimeInterval(connectTimeout)
            let epoch = stopEpoch
            while allSubscribed()[central] == nil, Date() < deadline, epoch == stopEpoch {
                _ = await wait(seconds: 0.5) { subscribeWaiters.append($0) }
            }
            manager?.stopAdvertising()
            guard allSubscribed()[central] != nil else { throw BLEKeyboardError.notConnected }
        }
        let settle = Self.linkSettleSec - Date().timeIntervalSince(subscribedAt[central] ?? .distantPast)
        if settle > 0 { try await Task.sleep(nanoseconds: UInt64(settle * 1e9)) }
        if let beforeFirstKey, !beforeFirstKey() { throw BLEKeyboardError.stale }
        do {
            for step in reports {
                try await send(Data(step.report), to: central)
                try await Task.sleep(nanoseconds: UInt64(max(step.delayAfterMs, 0)) * 1_000_000)
            }
        } catch {
            // Never leave a key held down on the phone.
            try? await send(Data(HIDKeyboard.releaseReport), to: central)
            throw error is BLEKeyboardError ? error : BLEKeyboardError.sendFailed
        }
        NSLog("iMirror: keyboard sent \(reports.count) reports")
    }

    /// Stops advertising and removes the services, so phones drop the keyboard.
    func stop() {
        stopEpoch += 1
        manager?.stopAdvertising()
        manager?.removeAllServices()
        servicesAdded = false
        reportSubs = [:]
        bootSubs = [:]
        subscribedAt = [:]
        // HIDS: each new connection starts in report mode.
        protocolMode = HIDKeyboard.reportProtocol
        leds = 0
        publishLinks()
        fireAll(&subscribeWaiters, false)
        fireAll(&readyWaiters, false)
    }

    // MARK: - Setup

    private func ensurePoweredOn() async throws {
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        }
        guard let m = manager else { return }
        if m.state == .unknown || m.state == .resetting {
            // The first call may wait on the macOS Bluetooth prompt.
            _ = await wait(seconds: 60) { stateWaiters.append($0) }
        }
        guard m.state == .poweredOn else {
            throw BLEKeyboardError.bluetoothUnavailable(Self.describe(m.state))
        }
    }

    private func ensureServices() async throws {
        try await ensurePoweredOn()
        guard !servicesAdded, let m = manager else { return }
        m.removeAllServices()
        for service in buildServices() {
            addFailed = false
            m.add(service)
            let added = await wait(seconds: 5) { addWaiters.append($0) }
            guard added, !addFailed else {
                m.removeAllServices()
                throw BLEKeyboardError.serviceSetupFailed
            }
        }
        servicesAdded = true
    }

    /// Device Information, Battery, then HID. Values are served on read
    /// (value: nil), because a fixed value forbids encryption.
    private func buildServices() -> [CBMutableService] {
        chars = Chars()
        func plain(_ short: String, _ props: CBCharacteristicProperties,
                   _ perms: CBAttributePermissions) -> CBMutableCharacteristic {
            CBMutableCharacteristic(type: Self.sig(short), properties: props, value: nil, permissions: perms)
        }
        let readEnc: CBAttributePermissions = [.readEncryptionRequired]

        let dis = CBMutableService(type: Self.sig("180A"), primary: true)
        dis.characteristics = [plain("2A29", .read, readEnc), plain("2A50", .read, readEnc)]

        let bas = CBMutableService(type: Self.sig("180F"), primary: true)
        bas.characteristics = [chars.battery]

        let hid = CBMutableService(type: Self.sig("1812"), primary: true)
        hid.characteristics = [
            plain("2A4A", .read, readEnc),                                          // HID Information
            plain("2A4B", .read, readEnc),                                          // Report Map
            // Protocol Mode: the phone may switch boot/report mode.
            plain("2A4E", [.read, .writeWithoutResponse], [.readEncryptionRequired, .writeEncryptionRequired]),
            plain("2A4C", .writeWithoutResponse, [.writeEncryptionRequired]),       // HID Control Point
            chars.inputReport, chars.outputReport, chars.bootInput, chars.bootOutput,
        ]
        return [dis, bas, hid]
    }

    private func startAdvertising() {
        guard let m = manager, !m.isAdvertising else { return }
        // CoreBluetooth cannot advertise an appearance; only name and UUIDs.
        // Short 1812 on air: the 128-bit form pushed it out of the
        // 31-byte packet, so iOS Settings never listed the keyboard.
        m.startAdvertising([CBAdvertisementDataLocalNameKey: HIDKeyboard.localName,
                            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")]])
    }

    // MARK: - Sending

    private func allSubscribed() -> [UUID: CBCentral] {
        reportSubs.merging(bootSubs) { a, _ in a }
    }

    /// Boot mode uses the boot characteristic; report mode the Report one.
    private func send(_ data: Data, to id: UUID) async throws {
        let deadline = Date().addingTimeInterval(Self.sendTimeoutSec)
        while true {
            let boot = protocolMode == 0 && bootSubs[id] != nil
            guard let central = boot ? bootSubs[id] : reportSubs[id] ?? bootSubs[id], let m = manager else {
                throw BLEKeyboardError.notConnected
            }
            let ch = (boot || reportSubs[id] == nil) ? chars.bootInput : chars.inputReport
            if m.updateValue(data, for: ch, onSubscribedCentrals: [central]) { return }
            // Queue full: wait for peripheralManagerIsReady, then retry.
            guard Date() < deadline else { throw BLEKeyboardError.sendFailed }
            _ = await wait(seconds: deadline.timeIntervalSinceNow) { readyWaiters.append($0) }
        }
    }

    // MARK: - Waiting

    private func wait(seconds: TimeInterval, _ register: (Waiter) -> Void) async -> Bool {
        await withCheckedContinuation { cont in
            let w = Waiter(cont)
            register(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0)) { w.fire(false) }
        }
    }

    private func fireAll(_ list: inout [Waiter], _ value: Bool) {
        let ws = list
        list = []
        ws.forEach { $0.fire(value) }
    }

    // MARK: - Pairs file

    func loadPairs() -> KeyboardPairs { pairsFile.load() }

    func savePairs(_ pairs: KeyboardPairs) { pairsFile.save(pairs) }

    // MARK: - Reads and writes from the phone

    private func value(for ch: CBCharacteristic) -> Data? {
        if ch === chars.inputReport || ch === chars.bootInput { return Data(HIDKeyboard.releaseReport) }
        if ch === chars.outputReport || ch === chars.bootOutput { return Data([leds]) }
        switch ch.uuid {
        case Self.sig("2A4A"): return Data(HIDKeyboard.hidInformation)
        case Self.sig("2A4B"): return Data(HIDKeyboard.reportMap)
        case Self.sig("2A4E"): return Data([protocolMode])
        case Self.sig("2A50"): return Data(HIDKeyboard.pnpID)
        case Self.sig("2A29"): return Data("iMirror".utf8)
        case Self.sig("2A19"): return Data([100])
        default: return nil
        }
    }

    fileprivate func handleRead(_ m: CBPeripheralManager, _ request: CBATTRequest) {
        guard let v = value(for: request.characteristic) else {
            return m.respond(to: request, withResult: .readNotPermitted)
        }
        guard request.offset <= v.count else { return m.respond(to: request, withResult: .invalidOffset) }
        request.value = v.subdata(in: request.offset..<v.count)
        m.respond(to: request, withResult: .success)
    }

    /// LED and mode writes are kept; control-point suspend is ignored.
    fileprivate func handleWrites(_ m: CBPeripheralManager, _ requests: [CBATTRequest]) {
        for r in requests {
            guard let byte = r.value?.first else { continue }
            if r.characteristic === chars.outputReport || r.characteristic === chars.bootOutput {
                leds = byte
            } else if r.characteristic.uuid == Self.sig("2A4E"), byte <= 1 {
                protocolMode = byte
            }
        }
        // One answer covers the whole batch.
        if let first = requests.first { m.respond(to: first, withResult: .success) }
    }

    fileprivate func handleSubscribe(_ m: CBPeripheralManager, _ central: CBCentral, _ ch: CBCharacteristic) {
        let target: CBMutableCharacteristic
        if ch === chars.inputReport { target = chars.inputReport; reportSubs[central.identifier] = central }
        else if ch === chars.bootInput { target = chars.bootInput; bootSubs[central.identifier] = central }
        else { return }
        if subscribedAt[central.identifier] == nil { subscribedAt[central.identifier] = Date() }
        subscriptionLog.append((central.identifier.uuidString, Date()))
        if subscriptionLog.count > 64 { subscriptionLog.removeFirst(subscriptionLog.count - 64) }
        // Baseline key-up report, or some hosts never start reading.
        _ = m.updateValue(Data(HIDKeyboard.releaseReport), for: target,
                          onSubscribedCentrals: [central])
        NSLog("iMirror: keyboard central \(central.identifier.uuidString) subscribed")
        publishLinks()
        fireAll(&subscribeWaiters, true)
    }

    fileprivate func handleUnsubscribe(_ central: CBCentral, _ ch: CBCharacteristic) {
        if ch === chars.inputReport { reportSubs[central.identifier] = nil }
        if ch === chars.bootInput { bootSubs[central.identifier] = nil }
        if allSubscribed()[central.identifier] == nil { subscribedAt[central.identifier] = nil }
        publishLinks()
        fireAll(&readyWaiters, false)
    }

    fileprivate func handleState(_ m: CBPeripheralManager) {
        if m.state != .poweredOn {
            // Bluetooth went away: services are gone with it.
            servicesAdded = false
            reportSubs = [:]
            bootSubs = [:]
            subscribedAt = [:]
            publishLinks()
            fireAll(&readyWaiters, false)
        }
        fireAll(&stateWaiters, true)
    }

    /// Reports each central that joined or left since the last call. A phone
    /// on both input characteristics counts once.
    private func publishLinks() {
        let now = Set(allSubscribed().keys)
        let gone = linked.subtracting(now), new = now.subtracting(linked)
        linked = now
        gone.forEach { onLinkChange?($0, false) }
        new.forEach { onLinkChange?($0, true) }
    }

    fileprivate func handleAdd(_ error: Error?) {
        if error != nil { addFailed = true }
        fireAll(&addWaiters, true)
    }

    fileprivate func handleReady() { fireAll(&readyWaiters, true) }

    // MARK: - Descriptions (no secrets)

    static func describe(_ outcome: PairingOutcome) -> String {
        switch outcome {
        case .paired(let c): return "paired \(c)"
        case .ambiguous(let n): return "ambiguous (\(n) new centrals)"
        case .none: return "no phone subscribed"
        }
    }

    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access was refused"
        case .unsupported: return "Bluetooth LE peripheral mode is unsupported"
        case .resetting: return "Bluetooth is resetting"
        case .unknown: return "Bluetooth state unknown"
        case .poweredOn: return "Bluetooth is on"
        @unknown default: return "Bluetooth state \(state.rawValue)"
        }
    }
}

// CoreBluetooth calls these on the main queue.
extension BLEKeyboard: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { handleState(peripheral) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                                       error: Error?) {
        MainActor.assumeIsolated { handleAdd(error) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { handleSubscribe(peripheral, central, characteristic) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { handleUnsubscribe(central, characteristic) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated { handleRead(peripheral, request) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated { handleWrites(peripheral, requests) }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { handleReady() }
    }
}

/// The characteristics that reads and subscriptions are matched against,
/// by identity. Made fresh for each service build, since a characteristic
/// belongs to one service only.
private struct Chars {
    let inputReport: CBMutableCharacteristic
    let outputReport: CBMutableCharacteristic
    let bootInput: CBMutableCharacteristic
    let bootOutput: CBMutableCharacteristic
    let battery: CBMutableCharacteristic

    init() {
        let sig = BLEKeyboard.sig
        let readEnc: CBAttributePermissions = [.readEncryptionRequired]
        let readWriteEnc: CBAttributePermissions = [.readEncryptionRequired, .writeEncryptionRequired]
        let output: CBCharacteristicProperties = [.read, .write, .writeWithoutResponse]
        inputReport = CBMutableCharacteristic(type: sig("2A4D"), properties: [.read, .notify], value: nil,
                                              permissions: readEnc)
        inputReport.descriptors = [CBMutableDescriptor(type: sig("2908"),
                                                       value: Data(HIDKeyboard.inputReportReference))]
        outputReport = CBMutableCharacteristic(type: sig("2A4D"), properties: output, value: nil,
                                               permissions: readWriteEnc)
        outputReport.descriptors = [CBMutableDescriptor(type: sig("2908"),
                                                        value: Data(HIDKeyboard.outputReportReference))]
        bootInput = CBMutableCharacteristic(type: sig("2A22"), properties: [.read, .notify], value: nil,
                                            permissions: readEnc)
        bootOutput = CBMutableCharacteristic(type: sig("2A32"), properties: output, value: nil,
                                             permissions: readWriteEnc)
        battery = CBMutableCharacteristic(type: sig("2A19"), properties: [.read, .notify], value: nil,
                                          permissions: readEnc)
    }
}
