// AutoUnlock — when a phone with auto-unlock on is found locked while its
// WDA is down, iMirror wakes it, checks the lock again, types the passcode
// and checks that the phone unlocked. Every decision is PasscodeGate's
// (iMirrorCore/PasscodeGate.swift); this file feeds it lock readings and
// carries out its steps through KeyboardControl.
//
// Off for every phone until a person turns it on (Settings, or an
// imirror-ctl request). A failed try turns it off again, saved, with a
// notification. The passcode never passes through here: KeyboardControl
// reads it at the moment it types. Main thread only.

import Foundation
import iMirrorCore

/// What the driver needs from one phone. DeviceController conforms.
protocol AutoUnlockPhone: AnyObject {
    var udid: String { get }
    var alias: String { get }
    /// Is the Mac asleep, is the sheet up, does WDA answer?
    var autoUnlockFacts: (macAsleep: Bool, sheetUp: Bool, wdaUp: Bool) { get }
    /// The newest lock reading, unknown ones included.
    var latestLock: LockSample? { get }
    /// When the lock probe now running started; nil when none runs.
    var lockProbeInFlightSince: TimeInterval? { get }
    func probeLockNow()
}

extension DeviceController: AutoUnlockPhone {
    var autoUnlockFacts: (macAsleep: Bool, sheetUp: Bool, wdaUp: Bool) {
        (macAsleep, runwdaClass == .needsPasscode || (chain?.passcodeHeld ?? false), health == .connected)
    }
    var latestLock: LockSample? { lockWatch.latest }
}

@MainActor
final class AutoUnlockDriver {
    private let keyboard: KeyboardControl
    private let defaults: UserDefaults
    private let notify: (_ title: String, _ body: String) -> Void
    private let writeEvent: (DeviceEvent) -> Void
    private var settings: AutoUnlockSettings
    private var gates: [String: PasscodeGate] = [:]
    /// The last phone object seen per UDID. Kept after it detaches, so
    /// a try in progress still ends (and frees the keyboard).
    private var phones: [String: AutoUnlockPhone] = [:]
    private var timer: Timer?
    private var clicks: [String: ClickVerify] = [:]
    /// When a phone was last seen unlocked by auto-unlock or a click.
    private var unlockedBy: [String: (cause: String, at: TimeInterval)] = [:]
    private var lastUnlockedWall: [String: Date] = [:]
    /// Settings or devices.json should redraw.
    var onChange: (() -> Void)?
    /// Monotonic seconds, the clock lock readings use; tests move it.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Tests pass `ticking: false` and call tick themselves.
    init(keyboard: KeyboardControl, defaults: UserDefaults = .standard,
         notify: @escaping (_ title: String, _ body: String) -> Void,
         writeEvent: @escaping (DeviceEvent) -> Void = { EventLog.shared.write($0) }, ticking: Bool = true) {
        self.keyboard = keyboard
        self.defaults = defaults
        self.notify = notify
        self.writeEvent = writeEvent
        let (loaded, interrupted) = AutoUnlockSettings.load(defaults.data(forKey: AutoUnlockSettings.defaultsKey),
                                                            wallNow: Date())
        settings = loaded
        save()
        // iMirror stopped mid-attempt: we can't know what was typed.
        for udid in interrupted {
            log(udid, alias: keyboard.aliasOf(udid) ?? "", .autoFailed, AutoUnlockReason.interrupted.rawValue)
            notifyOff(udid, alias: keyboard.aliasOf(udid), why: "iMirror stopped in the middle of an attempt.")
        }
        keyboard.onAutoRequest = { [weak self] udid, on in self?.requested(udid, on: on) }
        keyboard.onClickTyped = { [weak self] udid in self?.clickTyped(udid) }
        keyboard.autoHolds = { [weak self] udid in self?.gates[udid]?.inProgress ?? false }
        guard ticking else { return }
        let t = Timer(timeInterval: AutoUnlockTiming.verifyProbeIntervalSec, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Verify windows and deadlines need a clock, even for a phone that
    /// has stopped sending readings.
    private func tickAll() {
        for phone in phones.values { tick(phone) }
    }

    // MARK: Settings and requests

    func record(_ udid: String) -> AutoUnlockRecord { gates[udid]?.record ?? settings.record(for: udid) }

    /// devices.json `auto_unlock`, or nil for a phone with no pairing.
    func registryState(_ udid: String) -> String? {
        keyboard.pairs().pair(for: udid) == nil ? nil : record(udid).state.rawValue
    }

    /// Turn it on or off. On needs a pairing and a value in the file;
    /// callers check both first. Returns false when nothing changed.
    @discardableResult
    func setEnabled(_ udid: String, _ on: Bool, by: AutoUnlockChangeSource) -> Bool {
        guard ExpectedReset.fileName(udid: udid) != nil else { return false }
        var g = gate(udid)
        g.setEnabled(on, by: by, wallNow: Date())
        gates[udid] = g
        persist(g)
        let why = by == .request ? AutoUnlockReason.request : .settings
        log(udid, alias: keyboard.aliasOf(udid) ?? "", on ? .autoOn : .autoOff, why.rawValue)
        onChange?()
        return true
    }

    private func requested(_ udid: String, on: Bool) {
        if on, keyboard.pairs().pair(for: udid) == nil {
            return keyboard.log(udid, .failed, .notPaired)
        }
        setEnabled(udid, on, by: .request)
    }

    /// One line for Settings, or nil for a phone with no pairing.
    func statusText(_ udid: String, alias: String) -> String? {
        guard keyboard.pairs().pair(for: udid) != nil else { return nil }
        let r = record(udid)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        switch r.state {
        case .on:
            // Show when an agent, not a person, turned it on.
            let how = r.changedBy == .request ? " (turned on by a request)" : ""
            return "Auto-unlock: on\(how)"
                + (lastUnlockedWall[udid].map { " · last unlocked \(f.string(from: $0))" } ?? "")
        case .off:
            return "Auto-unlock: off"
        case .offAfterFailure:
            let at = r.changedAt.map { " at \(f.string(from: $0))" } ?? ""
            let key = PasscodeLookup.suggestedKey(udid: udid, alias: alias)
            return "Auto-unlock: off after a failed try\(at). Check \(key), then turn it on again."
        }
    }

    // MARK: Lock readings and steps

    private func gate(_ udid: String) -> PasscodeGate {
        gates[udid] ?? PasscodeGate(udid: udid, history: settings.record(for: udid))
    }

    /// May a locked phone keep the Mac awake? Only while its gate could
    /// still type (PasscodeGate.mayStillAct), so never for good.
    func mayStillAct(_ udid: String) -> Bool { gates[udid]?.mayStillAct(now: uptime()) ?? false }

    /// The phone's alias changed, so the key its passcode is read under
    /// did too (PHONE2_PASSCODE). Typing another phone's code would be
    /// a wrong attempt, so auto-unlock goes off until a person checks.
    func aliasChanged(_ udid: String, to alias: String) {
        guard record(udid).enabled else { return }
        var g = gate(udid)
        g.setEnabled(false, by: .settings, wallNow: Date())
        gates[udid] = g
        persist(g)
        log(udid, alias: alias, .autoOff, AutoUnlockReason.renamed.rawValue)
        notifyOff(udid, alias: alias, why: "The phone was renamed, so its passcode key changed.")
        onChange?()
    }

    /// Who unlocked the phone, for the lock event.
    func unlockCause(_ udid: String) -> String {
        if gates[udid]?.inProgress == true { return "auto" }
        if let u = unlockedBy[udid], uptime() - u.at <= AutoUnlockTiming.verifySec {
            return u.cause
        }
        if clicks[udid] != nil { return "click" }
        return "other"
    }

    func reading(_ phone: AutoUnlockPhone, _ r: LockReading, startedAt: TimeInterval) {
        phones[phone.udid] = phone
        var g = gate(phone.udid)
        g.reading(r, startedAt: startedAt)
        gates[phone.udid] = g
        persist(g)
        clicks[phone.udid]?.reading(r, startedAt: startedAt)
        step(phone)
        checkClick(phone)
    }

    /// Once a second: only an attempt or a click check needs the clock.
    func tick(_ phone: AutoUnlockPhone) {
        if gates[phone.udid]?.inProgress == true { step(phone) }
        if clicks[phone.udid] != nil {
            checkClick(phone)
            if clicks[phone.udid] != nil { phone.probeLockNow() }
        }
    }

    private func context(_ phone: AutoUnlockPhone) -> PasscodeGateContext {
        let f = phone.autoUnlockFacts
        return PasscodeGateContext(
            enabled: record(phone.udid).enabled,
            paired: keyboard.pairs().pair(for: phone.udid) != nil,
            attached: keyboard.aliasOf(phone.udid) != nil,
            macAsleep: f.macAsleep, sheetUp: f.sheetUp, wdaUp: f.wdaUp,
            keyboardBusy: keyboard.busy && keyboard.autoSequenceUDID != phone.udid,
            clickChecking: clicks[phone.udid] != nil, probeInFlightSince: phone.lockProbeInFlightSince)
    }

    /// Carry a SEND's end into the gate even when the phone object that
    /// started it is gone (detached or replaced), so the try never sticks.
    private func afterSend(_ udid: String, endSequence: Bool, _ change: (inout PasscodeGate) -> Void) {
        var g = gate(udid)
        change(&g)
        gates[udid] = g
        persist(g)
        if endSequence { keyboard.endAutoSequence() }
        if let phone = phones[udid] { step(phone) }
    }

    private func step(_ phone: AutoUnlockPhone) {
        let udid = phone.udid
        var g = gate(udid)
        let now = uptime()
        let next = g.decide(context(phone), now: now, wallNow: Date())
        gates[udid] = g
        persist(g)
        switch next {
        case .nothing:
            break
        case .probe:
            phone.probeLockNow()
        case .verifyProbe:
            // About once a second, not after every reading.
            let last = g.latest?.startedAt ?? -.infinity
            if now - last >= AutoUnlockTiming.verifyProbeIntervalSec { phone.probeLockNow() }
        case .wake:
            guard keyboard.beginAutoSequence(udid: udid) else { return }
            // Saved before any key, so a crash turns auto off.
            g.wakeStarted(now: now, wallNow: Date())
            gates[udid] = g
            persist(g)
            log(udid, alias: phone.alias, .autoWake, nil)
            keyboard.sendAutoWake(udid: udid) { [weak self] failure in
                guard let self else { return }
                let t = self.uptime()
                self.afterSend(udid, endSequence: false) { $0.wakeEnded(now: t, failure: failure) }
            }
        case .type(let approval):
            // Same main-thread turn as decide: the approval is fresh.
            keyboard.typePasscodeAutomatically(approval) { [weak self] result, age in
                guard let self else { return }
                let t = self.uptime()
                // Typing is over; verify needs no keys.
                self.afterSend(udid, endSequence: true) { $0.typingEnded(result, now: t, firstKeyAgeSec: age) }
            }
        case .finished(let outcome):
            if keyboard.autoSequenceUDID == udid { keyboard.endAutoSequence() }
            finished(phone, outcome)
        }
    }

    private func finished(_ phone: AutoUnlockPhone, _ o: AutoUnlockOutcome) {
        let udid = phone.udid
        switch o {
        case .unlocked:
            unlockedBy[udid] = ("auto", uptime())
            lastUnlockedWall[udid] = Date()
            log(udid, alias: phone.alias, .autoUnlocked, nil)
        case .stillLocked, .unverified, .interrupted, .unlockedLate, .lateFirstKey:
            log(udid, alias: phone.alias, .autoFailed, o.eventReason)
            notifyOff(udid, alias: phone.alias, why: Self.failureText(o))
        case .unlockedBeforeTyping, .aborted, .notSent:
            log(udid, alias: phone.alias, .autoAborted, o.eventReason)
        }
        onChange?()
    }

    /// Plain words for the notification; never digits from the file.
    private static func failureText(_ o: AutoUnlockOutcome) -> String {
        switch o {
        case .stillLocked: return "It typed the passcode and the phone stayed locked."
        case .unlockedLate:
            return "The phone unlocked too long after typing to prove the passcode did it (Face ID?)."
        case .lateFirstKey:
            return "The keyboard took too long to connect, so the phone may have unlocked before the keys arrived."
        default: return "It typed the passcode and could not tell whether the phone unlocked."
        }
    }

    // MARK: A clicked passcode

    /// A click spends this lock's try, so auto never repeats its value.
    private func clickTyped(_ udid: String) {
        let now = uptime()
        unlockedBy[udid] = ("click", now)
        var g = gate(udid)
        g.clickTyped(wallNow: Date(), now: now)
        gates[udid] = g
        persist(g)
        guard let v = ClickVerify(typedAt: now, lastBefore: gates[udid]?.latest) else { return }
        clicks[udid] = v
    }

    /// A click that leaves the phone locked means the file's value is
    /// probably wrong, so auto-unlock goes off the same way.
    private func checkClick(_ phone: AutoUnlockPhone) {
        let udid = phone.udid
        guard let v = clicks[udid], let o = v.outcome(now: uptime()) else { return }
        clicks[udid] = nil
        switch o {
        case .unlocked:
            unlockedBy[udid] = ("click", uptime())
            lastUnlockedWall[udid] = Date()
        case .stillLocked where record(udid).enabled:
            var g = gate(udid)
            g.clickFailed(wallNow: Date())
            gates[udid] = g
            persist(g)
            log(udid, alias: phone.alias, .autoOff, AutoUnlockReason.stillLocked.rawValue)
            notifyOff(udid, alias: phone.alias, why: "A clicked passcode left the phone locked.")
        default:
            break
        }
        onChange?()
    }

    // MARK: Output

    private func persist(_ g: PasscodeGate) {
        guard settings.record(for: g.udid) != g.record else { return }
        settings.set(g.record, for: g.udid)
        save()
        onChange?()
    }

    private func save() { defaults.set(settings.encode(), forKey: AutoUnlockSettings.defaultsKey) }

    private func log(_ udid: String, alias: String, _ d: KeyboardEventDetail, _ reason: String?) {
        writeEvent(.keyboard(at: Date(), udid: udid, alias: alias, d, reason: reason))
    }

    /// Plain words, never digits from the file.
    private func notifyOff(_ udid: String, alias: String?, why: String) {
        let name = alias ?? udid
        let key = PasscodeLookup.suggestedKey(udid: udid, alias: alias)
        notify("iMirror turned off auto-unlock for \(name)",
               "\(why) Check \(key) in the passcode file, then turn it on again in Settings.")
    }
}
