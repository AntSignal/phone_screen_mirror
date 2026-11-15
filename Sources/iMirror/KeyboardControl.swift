// KeyboardControl — acts on keyboard request files (pair, forget, test) with
// BLEKeyboard, and logs each outcome as a "keyboard" event. The rules live in
// iMirrorCore/KeyboardRequests.swift; this file only does the work and the I/O.
//
// One run at a time. After each run the keyboard stops (no advertising, no
// services), so the phone drops it and its on-screen keyboard comes back.
//
// Events carry counts, never text. Main thread only.

import Foundation
import iMirrorCore

@MainActor
final class KeyboardControl {
    let keyboard: BLEKeyboard
    /// An attached phone's alias, or nil when it is not attached.
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
            // The request parser only lets through [a-z0-9 ] with a letter.
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
