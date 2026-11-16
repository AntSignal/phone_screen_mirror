// AutoUnlockDriver end to end, with a fake keyboard, a fake phone and a
// fake clock. The real KeyboardControl reads a temp passcode file holding
// a dummy value (222222), so these check it never leaks into an event, a
// log line, devices.json or the stored settings.

import AppKit
import XCTest
@testable import iMirrorCore
@testable import iMirror

private let udid = "00008140-0006423002D3401C"
private let dummy = "222222"

@MainActor
private final class FakeKeyboard: KeyboardTransport {
    var kind: KeyboardTransportKind { .dongle }
    var sends: [[KeyStep]] = []
    var fail: Error?
    /// Each SEND takes time; the test clock moves on.
    var onType: (() -> Void)?
    func pair(udid: String, window: TimeInterval) async throws -> PairingOutcome { .none }
    func type(_ steps: [KeyStep], to pair: KeyboardPair) async throws {
        onType?()
        if let fail { throw fail }
        sends.append(steps)
    }
    func forget(_ pair: KeyboardPair) async throws {}
    func stop() {}

    /// True when any SEND held a digit key (usages 0x1E-0x27).
    var sentDigits: Bool { sends.joined().contains { (0x1E...0x27).contains($0.report[2]) } }
}

private final class FakePhone: AutoUnlockPhone, @unchecked Sendable {
    let udid = iMirror_udid
    let alias = "phone2"
    var autoUnlockFacts: (macAsleep: Bool, sheetUp: Bool, wdaUp: Bool) = (false, false, false)
    var latestLock: LockSample?
    var probes = 0
    /// What the next probe reads; nil leaves the probe unanswered.
    var answer: (() -> LockReading)?
    weak var driver: AutoUnlockDriver?
    var clock: () -> TimeInterval = { 0 }

    func probeLockNow() {
        probes += 1
        guard let answer else { return }
        let r = answer(), at = clock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.driver?.reading(self, r, startedAt: at) }
        }
    }
}

private let iMirror_udid = udid

@MainActor
final class AutoUnlockDriverTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var events: [DeviceEvent] = []
    private var notes: [String] = []
    private var now: TimeInterval = 10_000
    private var keyboard: KeyboardControl!
    private var fake: FakeKeyboard!
    private var phone: FakePhone!
    private var driver: AutoUnlockDriver!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("iMirror-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "PHONE2_PASSCODE=\(dummy)\n".write(to: dir.appendingPathComponent("secrets.env"),
                                              atomically: true, encoding: .utf8)
        var pairs = KeyboardPairs()
        _ = pairs.record(udid: udid, slot: "000081400006423002d3401c", peer: "AA:BB:CC:DD:EE:FF", at: Date())
        try pairs.encode().write(to: dir.appendingPathComponent("keyboard-pairs.json"))
        suite = "imirror.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        events = []
        notes = []
        now = 10_000
        makeDriver()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDriver() {
        keyboard = KeyboardControl(dir: dir, watchDongle: false)
        fake = FakeKeyboard()
        fake.onType = { [unowned self] in self.now += 1 }
        keyboard.transportOverride = fake
        keyboard.aliasOf = { $0 == udid ? "phone2" : nil }
        keyboard.passcodeFile = { [dir] in dir!.appendingPathComponent("secrets.env") }
        keyboard.uptime = { [unowned self] in self.now }
        keyboard.writeEvent = { [unowned self] in self.events.append($0) }
        driver = AutoUnlockDriver(keyboard: keyboard, defaults: defaults,
                                  notify: { [unowned self] t, b in self.notes.append(t + " " + b) },
                                  writeEvent: { [unowned self] in self.events.append($0) }, ticking: false)
        driver.uptime = { [unowned self] in self.now }
        phone = FakePhone()
        phone.driver = driver
        phone.clock = { [unowned self] in self.now }
    }

    /// Let queued main-thread work run.
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }

    /// Run the main queue until `done` or two seconds pass.
    private func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    private func details() -> [String] { events.compactMap(\.detail) }

    /// Locked for 30 s: settled, so the next reading may wake it.
    private func lockedLongEnough() {
        driver.reading(phone, .locked, startedAt: now - 30)
    }

    private func allText() -> String {
        let lines = events.map { String(decoding: DeviceEventCodec.line($0), as: UTF8.self) }
        return lines.joined() + notes.joined()
            + String(decoding: defaults.data(forKey: AutoUnlockSettings.defaultsKey) ?? Data(), as: UTF8.self)
    }

    func testEveryPhoneStartsOff() {
        XCTAssertFalse(driver.record(udid).enabled)
        lockedLongEnough()
        phone.answer = { .locked }
        driver.reading(phone, .locked, startedAt: now)
        drain()
        XCTAssertTrue(fake.sends.isEmpty)
        XCTAssertEqual(driver.registryState(udid), "off")
        XCTAssertNil(driver.registryState("00008150-001928E01404401C"), "no pairing, no field")
    }

    func testTheHappyPath() throws {
        let stderrText = try captureStderr {
            driver.setEnabled(udid, true, by: .settings)
            lockedLongEnough()
            phone.answer = { [unowned self] in self.now += 0.3; return .locked }
            driver.reading(phone, .locked, startedAt: now)
            spin { details().contains("auto_typed") }
            XCTAssertEqual(fake.sends.count, 2, "the wake, then the passcode")
            XCTAssertEqual(fake.sends.first, HIDKeyboard.wakeOnly())
            XCTAssertEqual(driver.unlockCause(udid), "auto")
            now += 3
            driver.reading(phone, .unlocked, startedAt: now)
            spin { details().contains("auto_unlocked") }
        }
        XCTAssertEqual(details().filter { $0.hasPrefix("auto_") }, ["auto_on", "auto_wake", "auto_typed", "auto_unlocked"])
        let typed = try XCTUnwrap(events.first { $0.detail == "auto_typed" })
        XCTAssertEqual(typed.chars, 6)
        XCTAssertNotNil(typed.probeAgeMs)
        XCTAssertEqual(driver.unlockCause(udid), "auto")
        XCTAssertTrue(driver.record(udid).enabled)
        XCTAssertNil(driver.record(udid).pendingSince)
        let entry = RegisteredDevice(udid: udid, alias: "phone2", kind: .device, wdaURL: "x", state: .down,
                                     autoUnlock: driver.registryState(udid))
        let registry = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertTrue(registry.contains("\"auto_unlock\":\"on\""))
        for text in [allText(), registry, stderrText] { XCTAssertFalse(text.contains(dummy)) }
    }

    func testStillLockedTurnsItOffForGood() {
        driver.setEnabled(udid, true, by: .settings)
        lockedLongEnough()
        phone.answer = { .locked }
        driver.reading(phone, .locked, startedAt: now)
        spin { details().contains("auto_typed") }
        for _ in 0..<16 {
            now += 1
            driver.tick(phone)
            drain()
        }
        XCTAssertEqual(events.last { $0.detail == "auto_failed" }?.reason, "still_locked")
        XCTAssertFalse(driver.record(udid).enabled)
        XCTAssertEqual(driver.registryState(udid), "off_after_failure")
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasPrefix("iMirror turned off auto-unlock for phone2"))
        // Saved: a fresh driver reads it off too.
        makeDriver()
        XCTAssertFalse(driver.record(udid).enabled)
        XCTAssertEqual(driver.record(udid).disabledReason, .stillLocked)
        // No second wake, in this episode or after.
        let sendsBefore = fake.sends.count
        now += 600
        driver.reading(phone, .locked, startedAt: now)
        drain()
        XCTAssertEqual(fake.sends.count, sendsBefore)
        XCTAssertFalse(allText().contains(dummy))
    }

    func testUnknownBeforeTypingSendsNoDigits() {
        driver.setEnabled(udid, true, by: .settings)
        lockedLongEnough()
        phone.answer = { .unknown }
        driver.reading(phone, .locked, startedAt: now)
        spin { details().contains("auto_aborted") }
        XCTAssertFalse(fake.sentDigits)
        XCTAssertEqual(events.last?.reason, "lock_unknown")
        XCTAssertTrue(driver.record(udid).enabled, "nothing typed, so it stays on")
    }

    func testUnlockedAfterTheWakeSendsNoDigits() {
        driver.setEnabled(udid, true, by: .settings)
        lockedLongEnough()
        phone.answer = { .unlocked }   // Face ID during the wake
        driver.reading(phone, .locked, startedAt: now)
        spin { details().contains("auto_aborted") }
        XCTAssertFalse(fake.sentDigits)
        XCTAssertEqual(fake.sends.count, 1)
        XCTAssertEqual(events.last?.reason, "unlocked_before_typing")
    }

    func testAPendingAttemptAtLaunchIsReportedAndOff() {
        var s = AutoUnlockSettings()
        s.enable(udid: udid, by: .settings, at: Date())
        var r = s.record(for: udid)
        r.pendingSince = Date()
        s.set(r, for: udid)
        defaults.set(s.encode(), forKey: AutoUnlockSettings.defaultsKey)
        makeDriver()
        XCTAssertEqual(events.last?.detail, "auto_failed")
        XCTAssertEqual(events.last?.reason, "interrupted")
        XCTAssertFalse(driver.record(udid).enabled)
        XCTAssertEqual(notes.count, 1)
    }

    func testAClickDuringASequenceIsBusy() throws {
        XCTAssertTrue(keyboard.beginAutoSequence(udid: udid))
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let line = keyboard.typePasscodeFromClick(udid: udid, event: click, file: dir.appendingPathComponent("secrets.env"))
        XCTAssertTrue(line.contains("busy"), line)
        XCTAssertEqual(events.last?.reason, "busy")
        keyboard.endAutoSequence()
        XCTAssertFalse(keyboard.busy)
    }

    func testAStaleOrForeignApprovalTypesNothing() {
        var results: [TypeResult] = []
        XCTAssertTrue(keyboard.beginAutoSequence(udid: udid))
        keyboard.typePasscodeAutomatically(AutoTypeApproval(udid: udid, readingStartedAt: now - 2.5)) {
            results.append($0)
        }
        keyboard.typePasscodeAutomatically(AutoTypeApproval(udid: "00008150-001928E01404401C",
                                                            readingStartedAt: now)) { results.append($0) }
        keyboard.endAutoSequence()
        keyboard.typePasscodeAutomatically(AutoTypeApproval(udid: udid, readingStartedAt: now)) {
            results.append($0)
        }
        drain()
        XCTAssertEqual(results, [.notSent(.stale), .notSent(.stale), .notSent(.stale)],
                       "too old, another phone, no sequence")
        XCTAssertTrue(fake.sends.isEmpty)
    }

    func testRequestsTurnItOnAndOff() {
        keyboard.handle(.request(KeyboardRequest(udid: udid, requestedAt: Date(), requestedBy: "t", action: .autoOn)))
        XCTAssertTrue(driver.record(udid).enabled)
        XCTAssertEqual(events.last?.detail, "auto_on")
        XCTAssertEqual(events.last?.reason, "request")
        keyboard.handle(.request(KeyboardRequest(udid: udid, requestedAt: Date(), requestedBy: "t", action: .autoOff)))
        XCTAssertFalse(driver.record(udid).enabled)
        XCTAssertEqual(events.last?.detail, "auto_off")
    }

    func testAutoOnWithNoValueIsRefused() throws {
        try "OTHER=1\n".write(to: dir.appendingPathComponent("secrets.env"), atomically: true, encoding: .utf8)
        keyboard.handle(.request(KeyboardRequest(udid: udid, requestedAt: Date(), requestedBy: "t", action: .autoOn)))
        XCTAssertFalse(driver.record(udid).enabled)
        XCTAssertEqual(events.last?.detail, "failed")
        XCTAssertEqual(events.last?.reason, "no_passcode")
    }

    /// NSLog writes to stderr in a test run; point fd 2 at a file meanwhile.
    private func captureStderr(_ body: () throws -> Void) throws -> String {
        let url = dir.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        let saved = dup(2)
        dup2(fh.fileDescriptor, 2)
        defer { dup2(saved, 2); close(saved); try? fh.close() }
        try body()
        fflush(stderr)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// A locked phone, as devices.json shows it.
final class LockedControllerTests: XCTestCase {
    private func controller() -> (DeviceController, () -> [DeviceEvent]) {
        let c = DeviceController(udid: udid, slot: PortSlot(471), alias: "phone2",
                                 attached: AttachedDevice(udid: udid, productType: nil, productVersion: nil,
                                                          connection: "USB"), chain: nil)
        var events: [DeviceEvent] = []
        c.writeEvent = { events.append($0) }
        return (c, { events })
    }

    func testALockedPhoneReadsLockedNotFailed() {
        let (c, _) = controller()
        c.lockRead(.locked, startedAt: ProcessInfo.processInfo.systemUptime)
        let e = c.registryEntry(now: Date())
        XCTAssertEqual(e.reason, "locked")
        XCTAssertNotEqual(e.state, .failed)
        XCTAssertNil(e.nextRetryAt)
    }

    func testLockAndUnlockAreLoggedWithTheCause() {
        let (c, events) = controller()
        c.unlockCause = { "auto" }
        let t = ProcessInfo.processInfo.systemUptime
        c.lockRead(.locked, startedAt: t)
        c.lockRead(.unknown, startedAt: t + 1)
        c.lockRead(.unlocked, startedAt: t + 2)
        let lock = events().filter { $0.event == "lock" }
        XCTAssertEqual(lock.map(\.detail), ["locked", "unlocked"])
        XCTAssertEqual(lock.last?.reason, "auto")
        XCTAssertNotNil(c.ladder.unlockedAt, "the next tick restarts the chain")
    }
}
