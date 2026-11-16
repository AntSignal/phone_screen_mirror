// KeyboardControl — acts on keyboard request files (pair, forget, test) and
// on Settings → "Type passcode now", and logs each outcome as a "keyboard"
// event. Pairing uses the USB dongle when one answers HELLO, else this Mac's
// BLEKeyboard; typing uses whichever the phone was paired with. The rules
// live in iMirrorCore/KeyboardRequests.swift; this file only does the work.
//
// One run at a time. After each run the keyboard stops (no advertising, no
// services), so the phone drops it and its on-screen keyboard comes back.
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

    /// `dir` holds devices.json; the pairs file sits beside it.
    init(dir: URL) {
        pairsFile = KeyboardPairsFile(url: dir.appendingPathComponent("keyboard-pairs.json"))
        ble = BLEKeyboard(pairsURL: pairsFile.url)
        dongle = SerialDongleKeyboard(pairsFile: pairsFile)
        ble.onLinkChange = { [weak self] central, up in self?.linkChanged(central, up) }
        dongle.onStateChange = { [weak self] in self?.onChange?() }
        dongle.startWatching()
    }

    func pairs() -> KeyboardPairs { pairsFile.load() }

    /// The transport a phone was paired with.
    func transport(for pair: KeyboardPair) -> KeyboardTransport {
        pair.transport == .dongle ? dongle : ble
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
        case .autoOn, .autoOff:
            // Auto-unlock is not wired up yet: refuse rather than pretend.
            log(r.udid, .failed, .unknownAction, transport: pair?.transport)
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

    /// The one way a passcode is typed: a person clicked "Type passcode now".
    /// Only that button's action may call this; PasscodeCallSiteTests checks.
    /// Reads the value, wakes the phone, types it to that phone's central,
    /// zeroes the buffers and logs a count. Returns a line for the status bar.
    func typePasscodeFromClick(udid: String, event: NSEvent?, file: URL) -> String {
        guard Self.isHumanClick(event?.type) else { return "Type passcode: only a click can start this." }
        guard !busy else { log(udid, .failed, .busy); return "The keyboard is busy; try again in a moment." }
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
        run(udid, chars: chars, pick: { t }) { t in
            defer { HIDKeyboard.wipe(&steps) }
            try await t.type(steps, to: pair)
            return (.typedPasscode, chars)
        }
        return "Typing the passcode (\(chars) characters)…"
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
        EventLog.shared.write(.keyboard(at: Date(), udid: udid, alias: aliasOf(udid) ?? "", detail,
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
        case .sendFailed?, nil: return .sendFailed
        }
    }
}
