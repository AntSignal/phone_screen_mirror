// KeyboardControl — acts on keyboard request files (pair, forget, test,
// auto_on, auto_off), on Settings → "Type passcode now", and on
// auto-unlock's steps, and logs each outcome as a "keyboard" event.
// Pairing uses the USB dongle when one answers HELLO, else this Mac's
// BLEKeyboard; typing uses whichever the phone was paired with. The rules
// live in iMirrorCore (KeyboardRequests.swift, PasscodeGate.swift); this
// file only does the work.
//
// One run at a time; an auto-unlock sequence holds the keyboard from its
// wake to its last key, and its transport is not stopped in between, so
// this Mac's Bluetooth link stays up and the first key goes out at once.
// After each run the keyboard stops (no advertising, no services), so the
// phone drops it and its on-screen keyboard comes back.
//
// Events carry counts, never text. Main thread only.

import AppKit
import iMirrorCore

@MainActor
final class KeyboardControl {
    let pairsFile: KeyboardPairsFile
    let ble: BLEKeyboard
    let dongle: SerialDongleKeyboard
    /// An attached phone's alias; nil when not attached.
    var aliasOf: (String) -> String? = { _ in nil }
    /// A pairing changed or a run ended; Settings redraws.
    var onChange: (() -> Void)?
    private(set) var busy = false
    /// The phone whose auto-unlock sequence holds the keyboard.
    private(set) var autoSequenceUDID: String?
    /// The sequence's transport, stopped when the sequence ends.
    private var autoTransport: KeyboardTransport?
    /// True while auto-unlock is trying this phone, verify included.
    var autoHolds: (_ udid: String) -> Bool = { _ in false }
    /// A request asked to turn auto-unlock on or off (AutoUnlockDriver).
    var onAutoRequest: ((_ udid: String, _ on: Bool) -> Void)?
    /// A clicked passcode was sent; auto-unlock checks it took.
    var onClickTyped: ((_ udid: String) -> Void)?
    /// The secrets file, as Settings has it.
    var passcodeFile: () -> URL = {
        PasscodeFile.url(stored: UserDefaults.standard.string(forKey: PasscodeFile.defaultsKey))
    }
    /// Where events go. Tests swap it so nothing reaches the real log.
    var writeEvent: (DeviceEvent) -> Void = { EventLog.shared.write($0) }
    /// Tests only: a fake keyboard in place of the dongle and Bluetooth.
    var transportOverride: KeyboardTransport?
    /// Monotonic seconds; tests move it forward.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// `dir` holds devices.json; the pairs file sits beside it. Tests pass
    /// `watchDongle: false` so no USB polling starts.
    init(dir: URL, watchDongle: Bool = true) {
        pairsFile = KeyboardPairsFile(url: dir.appendingPathComponent("keyboard-pairs.json"))
        ble = BLEKeyboard(pairsURL: pairsFile.url)
        dongle = SerialDongleKeyboard(pairsFile: pairsFile)
        ble.onLinkChange = { [weak self] central, up in self?.linkChanged(central, up) }
        dongle.onStateChange = { [weak self] in self?.onChange?() }
        if watchDongle { dongle.startWatching() }
    }

    func pairs() -> KeyboardPairs { pairsFile.load() }

    /// The transport a phone was paired with.
    func transport(for pair: KeyboardPair) -> KeyboardTransport {
        if let t = transportOverride { return t }
        return pair.transport == .dongle ? dongle : ble
    }

    func handle(_ read: KeyboardRequestFile.Read) {
        switch read {
        case .refused(let udid, let why):
            NSLog("iMirror: keyboard request for \(udid) refused: \(why.rawValue)")
            log(udid, .failed, why)
        case .request(let r):
            act(r)
        case .notOurs, .unreadable:
            return
        }
    }

    private func act(_ r: KeyboardRequest) {
        let pair = pairs().pair(for: r.udid)
        if let why = KeyboardRequestGate.refusal(r, attached: aliasOf(r.udid) != nil, paired: pair != nil,
                                                 wallNow: Date()) {
            return log(r.udid, .failed, why, transport: pair?.transport)
        }
        NSLog("iMirror: keyboard \(r.action.rawValue) for \(r.udid) from \(r.requestedBy)")
        switch r.action {
        case .forget:
            forget(r.udid, pair)
        case .pair:
            // The dongle first: iOS hides this Mac from phones on its iCloud.
            run(r.udid, pick: { [dongle, ble] in await dongle.available() ? dongle : ble as KeyboardTransport }) { t in
                let outcome = try await t.pair(udid: r.udid, window: KeyboardRequestGate.pairWindowSec)
                return (KeyboardEventDetail(outcome), nil)
            }
        case .test:
            // The parser allows [a-z0-9 ], a letter, few digits.
            guard let text = r.text, let reports = HIDKeyboard.textReports(text), let pair else {
                return log(r.udid, .failed, .badText, transport: pair?.transport)
            }
            let t = transport(for: pair)
            run(r.udid, chars: text.count, pick: { t }) { t in
                try await t.type(reports, to: pair)
                return (.typedTest, text.count)
            }
        case .autoOn:
            // The value must exist now, not at the first lock.
            if let why = autoOnPrecheck(udid: r.udid) { return log(r.udid, .failed, why, transport: pair?.transport) }
            onAutoRequest?(r.udid, true)
        case .autoOff:
            onAutoRequest?(r.udid, false)
        }
    }

    /// Drops the tie at once, so forget works with no dongle on USB. The
    /// dongle's bond goes too when it answers; a leftover one is never
    /// used, since SEND names a slot only this file maps.
    private func forget(_ udid: String, _ pair: KeyboardPair?) {
        var p = pairs()
        p.forget(udid: udid)
        pairsFile.save(p)
        log(udid, .forgotten, transport: pair?.transport)
        onChange?()
        guard let pair, pair.transport == .dongle else { return }
        Task { @MainActor [dongle] in
            do { try await dongle.forget(pair) } catch {
                NSLog("iMirror: dongle kept the bond for \(udid): \(Self.failure(error).rawValue)")
            }
        }
    }

    /// Runs one keyboard job on the transport `pick` gives, logs its
    /// outcome, then stops that transport. `chars` goes on a failure line
    /// too, so a reader sees what was tried.
    func run(_ udid: String, chars: Int? = nil, pick: @escaping @MainActor () async -> KeyboardTransport,
             _ job: @escaping @MainActor (KeyboardTransport) async throws -> (KeyboardEventDetail, Int?)) {
        guard !busy else { return log(udid, .failed, .busy, chars: chars) }
        busy = true
        onChange?()
        Task { @MainActor in
            let t = await pick()
            do {
                let (detail, n) = try await job(t)
                log(udid, detail, chars: n, transport: t.kind)
            } catch {
                log(udid, .failed, Self.failure(error), chars: chars, transport: t.kind)
            }
            t.stop()
            busy = false
            onChange?()
        }
    }

    /// A person clicked "Type passcode now". Only that button's action may
    /// call this; PasscodeCallSiteTests checks. (The only other path is
    /// typePasscodeAutomatically, for a phone a person opted in.)
    /// Reads the value, wakes the phone, types it to that phone's central,
    /// zeroes the buffers and logs a count. Returns a line for the status bar.
    func typePasscodeFromClick(udid: String, event: NSEvent?, file: URL) -> String {
        guard Self.isHumanClick(event?.type) else { return "Type passcode: only a click can start this." }
        guard !busy else { log(udid, .failed, .busy); return "The keyboard is busy; try again in a moment." }
        // One lock, one file value, two tries: two wrong attempts.
        guard !autoHolds(udid) else {
            log(udid, .failed, .busy)
            return "Auto-unlock is checking its own try on this phone; try again in 20 seconds."
        }
        guard let pair = pairs().pair(for: udid) else {
            log(udid, .failed, .notPaired)
            return "Pair the keyboard first: scripts/imirror-ctl keyboard pair <device>."
        }
        let secret: SecretBytes
        let alias = aliasOf(udid)
        switch PasscodeLookup.load(udid: udid, alias: alias, file: file) {
        case .noFile:
            log(udid, .failed, .noFile)
            return "Can't read \(file.path)."
        case .noPasscode:
            log(udid, .failed, .noPasscode)
            return "\(file.lastPathComponent) has no \(PasscodeLookup.suggestedKey(udid: udid, alias: alias))."
        case .found(let s):
            secret = s
        }
        let t = transport(for: pair)
        let chars = secret.count
        let steps = HIDKeyboard.wakeThenPasscode(ascii: secret.bytes)
        secret.wipe()
        guard var steps else {
            log(udid, .failed, .untypeable, chars: chars, transport: t.kind)
            return "The passcode has a character the keyboard can't type."
        }
        run(udid, chars: chars, pick: { t }) { [weak self] t in
            defer { HIDKeyboard.wipe(&steps) }
            do { try await t.type(steps, to: pair) } catch {
                // Some keys may have gone out: auto-unlock must know.
                if case .maybeSent = TypeResult(failure: Self.failure(error)) { self?.onClickTyped?(udid) }
                throw error
            }
            self?.onClickTyped?(udid)
            return (.typedPasscode, chars)
        }
        return "Typing the passcode (\(chars) characters)…"
    }

    // MARK: Auto-unlock (decisions in iMirrorCore/PasscodeGate.swift)

    /// Hold the keyboard for one phone's auto-unlock, from the wake to
    /// the last key, so a click in between gets "busy".
    func beginAutoSequence(udid: String) -> Bool {
        guard !busy else { return false }
        busy = true
        autoSequenceUDID = udid
        onChange?()
        return true
    }

    func endAutoSequence() {
        guard autoSequenceUDID != nil else { return }
        autoSequenceUDID = nil
        autoTransport?.stop()
        autoTransport = nil
        busy = false
        onChange?()
    }

    /// Shift and the wake settle, to the paired phone only. `done` gets
    /// nil when sent. The transport stays up for the passcode.
    func sendAutoWake(udid: String, done: @escaping (KeyboardFailure?) -> Void) {
        guard autoSequenceUDID == udid, let pair = pairs().pair(for: udid) else { return done(.notPaired) }
        let t = transport(for: pair)
        autoTransport = t
        Task { @MainActor in
            var failure: KeyboardFailure?
            do { try await t.type(HIDKeyboard.autoWake(), to: pair) } catch { failure = Self.failure(error) }
            done(failure)
        }
    }

    /// The one automatic way a passcode is typed. Only AutoUnlock.swift
    /// calls it, for a `.type` step; PasscodeCallSiteTests checks. Re-checks
    /// the approval's age and the pairing, reads the value, types it to
    /// that phone's peer only, zeroes the buffers and logs a count. `done`
    /// gets the reading's age at the first key (FirstKeyAge), which the
    /// gate holds to firstKeyMaxSec.
    func typePasscodeAutomatically(_ a: AutoTypeApproval,
                                   done: @escaping (TypeResult, _ firstKeyAgeSec: TimeInterval?) -> Void) {
        let now = uptime()
        guard autoSequenceUDID == a.udid, a.isFresh(now: now) else { return done(.notSent(.stale), nil) }
        guard let pair = pairs().pair(for: a.udid) else { return done(.notSent(.notPaired), nil) }
        let secret: SecretBytes
        switch PasscodeLookup.load(udid: a.udid, alias: aliasOf(a.udid), file: passcodeFile()) {
        case .noFile: return done(.notSent(.noFile), nil)
        case .noPasscode: return done(.notSent(.noPasscode), nil)
        case .found(let s): secret = s
        }
        let chars = secret.count
        let steps = HIDKeyboard.passcodeAfterWake(ascii: secret.bytes)
        secret.wipe()
        guard var steps else { return done(.notSent(.untypeable), nil) }
        let t = autoTransport ?? transport(for: pair)
        autoTransport = t
        let probeAgeMs = Int((now - a.readingStartedAt) * 1000)
        let delaysMs = steps.reduce(0) { $0 + max($1.delayAfterMs, 0) }
        let firstKey = FirstKeyMark()
        // Rechecked at the first key where the transport sees it.
        let clock = uptime
        let check: FirstKeyCheck = {
            let at = clock()
            firstKey.at = at
            return a.isFresh(now: at)
        }
        Task { @MainActor in
            var failure: KeyboardFailure?
            do { try await t.type(steps, to: pair, beforeFirstKey: check) } catch { failure = Self.failure(error) }
            HIDKeyboard.wipe(&steps)
            let end = self.uptime()
            let age = FirstKeyAge.seconds(readingStartedAt: a.readingStartedAt, firstKeyAt: firstKey.at,
                                          sendStartedAt: now, sendEndedAt: end, stepDelaysMs: delaysMs)
            let sendMs = Int((end - now) * 1000)
            if let failure {
                log(a.udid, .failed, failure, chars: chars, transport: t.kind)
            } else {
                writeEvent(.keyboard(at: Date(), udid: a.udid, alias: aliasOf(a.udid) ?? "", .autoTyped,
                                     reason: nil, chars: chars, probeAgeMs: probeAgeMs, sendMs: sendMs,
                                     firstKeyAgeMs: Int(age * 1000), transport: t.kind))
            }
            done(TypeResult(failure: failure), age)
        }
    }

    /// Before auto-unlock is turned on: is there a value to type? Reads
    /// the file, wipes the value at once, and returns why not, or nil.
    func autoOnPrecheck(udid: String) -> KeyboardFailure? {
        switch PasscodeLookup.load(udid: udid, alias: aliasOf(udid), file: passcodeFile()) {
        case .noFile: return .noFile
        case .noPasscode: return .noPasscode
        case .found(let s):
            let typeable = HIDKeyboard.strokes(ascii: s.bytes) != nil
            s.wipe()
            return typeable ? nil : .untypeable
        }
    }

    /// True for a mouse click or a key press on the button, which only a
    /// person makes. Nil (called from code, not an action) is refused.
    nonisolated static func isHumanClick(_ type: NSEvent.EventType?) -> Bool {
        switch type {
        case .leftMouseUp?, .leftMouseDown?, .keyDown?, .keyUp?: return true
        default: return false
        }
    }

    private func linkChanged(_ central: UUID, _ up: Bool) {
        guard let udid = pairs().udid(forCentral: central.uuidString) else { return }
        log(udid, up ? .connected : .disconnected, transport: .corebluetooth)
        onChange?()
    }

    func log(_ udid: String, _ detail: KeyboardEventDetail, _ why: KeyboardFailure? = nil, chars: Int? = nil,
             transport: KeyboardTransportKind? = nil) {
        writeEvent(.keyboard(at: Date(), udid: udid, alias: aliasOf(udid) ?? "", detail,
                             reason: why, chars: chars, transport: transport))
    }

    nonisolated static func failure(_ error: Error) -> KeyboardFailure {
        if let e = error as? DongleError {
            switch e {
            case .notFound: return .dongleUnavailable
            case .noReply, .unplugged: return .dongleError
            case .failed(let why): return why
            }
        }
        switch error as? BLEKeyboardError {
        case .bluetoothUnavailable?: return .bluetoothUnavailable
        case .serviceSetupFailed?: return .setupFailed
        case .notConnected?: return .notConnected
        case .busy?: return .busy
        case .stale?: return .stale
        case .sendFailed?, nil: return .sendFailed
        }
    }
}

/// When a transport sent its first key, if it can tell.
@MainActor
private final class FirstKeyMark {
    var at: TimeInterval?
}
