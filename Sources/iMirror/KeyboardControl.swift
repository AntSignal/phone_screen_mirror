// KeyboardControl — acts on keyboard request files (pair, forget, test) and
// on Settings → "Type passcode now" with BLEKeyboard, and logs each outcome
// as a "keyboard" event. The rules live in
// iMirrorCore/KeyboardRequests.swift; this file only does the work and the I/O.
//
// One run at a time. After each run the keyboard stops (no advertising, no
// services), so the phone drops it and its on-screen keyboard comes back.
//
// Events carry counts, never text. Main thread only.

import AppKit
import iMirrorCore

@MainActor
final class KeyboardControl {
    let keyboard: BLEKeyboard
    /// An attached phone's alias; nil when not attached.
    var aliasOf: (String) -> String? = { _ in nil }
    /// A pairing changed or a run ended; Settings redraws.
    var onChange: (() -> Void)?
    private(set) var busy = false

    /// `dir` holds devices.json; the pairs file sits beside it.
    init(dir: URL) {
        keyboard = BLEKeyboard(pairsURL: dir.appendingPathComponent("keyboard-pairs.json"))
        keyboard.onLinkChange = { [weak self] central, up in self?.linkChanged(central, up) }
    }

    func pairs() -> KeyboardPairs { keyboard.loadPairs() }

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
        let central = pairs().central(for: r.udid)
        if let why = KeyboardRequestGate.refusal(r, attached: aliasOf(r.udid) != nil, paired: central != nil,
                                                 wallNow: Date()) {
            return log(r.udid, .failed, why)
        }
        NSLog("iMirror: keyboard \(r.action.rawValue) for \(r.udid) from \(r.requestedBy)")
        switch r.action {
        case .forget:
            var p = pairs()
            p.forget(udid: r.udid)
            keyboard.savePairs(p)
            log(r.udid, .forgotten)
            onChange?()
        case .pair:
            run(r.udid) { kb in
                let outcome = try await kb.startPairing(udid: r.udid, window: KeyboardRequestGate.pairWindowSec)
                return (KeyboardEventDetail(outcome), nil)
            }
        case .test:
            // The parser allows [a-z0-9 ], a letter, few digits.
            guard let text = r.text, let reports = HIDKeyboard.textReports(text),
                  let id = central.flatMap(UUID.init(uuidString:)) else { return log(r.udid, .failed, .badText) }
            run(r.udid, chars: text.count) { kb in
                try await kb.type(reports: reports, to: id)
                return (.typedTest, text.count)
            }
        }
    }

    /// Runs one keyboard job, logs its outcome, then stops the keyboard.
    /// `chars` goes on a failure line too, so a reader sees what was tried.
    func run(_ udid: String, chars: Int? = nil,
             _ job: @escaping @MainActor (BLEKeyboard) async throws -> (KeyboardEventDetail, Int?)) {
        guard !busy else { return log(udid, .failed, .busy, chars: chars) }
        busy = true
        Task { @MainActor in
            do {
                let (detail, n) = try await job(keyboard)
                log(udid, detail, chars: n)
            } catch {
                log(udid, .failed, Self.failure(error), chars: chars)
            }
            keyboard.stop()
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
        guard let central = pairs().central(for: udid).flatMap(UUID.init(uuidString:)) else {
            log(udid, .failed, .notPaired)
            return "Pair the keyboard first: scripts/imirror-ctl keyboard pair <device>."
        }
        let secret: SecretBytes
        switch PasscodeLookup.load(udid: udid, file: file) {
        case .noFile:
            log(udid, .failed, .noFile)
            return "Can't read \(file.path)."
        case .noPasscode:
            log(udid, .failed, .noPasscode)
            return "\(file.lastPathComponent) has no \(PasscodeLookup.key(udid: udid))."
        case .found(let s):
            secret = s
        }
        let chars = secret.count
        let steps = HIDKeyboard.wakeThenPasscode(ascii: secret.bytes)
        secret.wipe()
        guard var steps else {
            log(udid, .failed, .untypeable, chars: chars)
            return "The passcode has a character the keyboard can't type."
        }
        run(udid, chars: chars) { kb in
            defer { HIDKeyboard.wipe(&steps) }
            try await kb.type(reports: steps, to: central)
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
        log(udid, up ? .connected : .disconnected)
        onChange?()
    }

    func log(_ udid: String, _ detail: KeyboardEventDetail, _ why: KeyboardFailure? = nil, chars: Int? = nil) {
        EventLog.shared.write(.keyboard(at: Date(), udid: udid, alias: aliasOf(udid) ?? "", detail,
                                        reason: why, chars: chars))
    }

    static func failure(_ error: Error) -> KeyboardFailure {
        switch error as? BLEKeyboardError {
        case .bluetoothUnavailable?: return .bluetoothUnavailable
        case .serviceSetupFailed?: return .setupFailed
        case .notConnected?: return .notConnected
        case .busy?: return .busy
        case .sendFailed?, nil: return .sendFailed
        }
    }
}
