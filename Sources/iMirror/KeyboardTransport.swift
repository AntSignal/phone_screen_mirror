// KeyboardTransport — the two ways iMirror types into a phone. The USB
// dongle (SerialDongleKeyboard) has its own Bluetooth address, so it works
// for phones on this Mac's iCloud account, which hide the Mac itself as
// "my Mac". BLEKeyboard (this Mac over CoreBluetooth) is the fallback when
// no dongle answers. Each phone's entry in keyboard-pairs.json says which
// one it is paired with. Main thread only.

import Foundation
import iMirrorCore

@MainActor
protocol KeyboardTransport: AnyObject {
    var kind: KeyboardTransportKind { get }
    /// Opens a pairing window for `udid`. On `.paired` the tie is saved.
    func pair(udid: String, window: TimeInterval) async throws -> PairingOutcome
    /// Types to the phone in `pair` and no other.
    func type(_ steps: [KeyStep], to pair: KeyboardPair) async throws
    /// Drops the transport's own memory of the phone, such as a bond.
    func forget(_ pair: KeyboardPair) async throws
    /// Ends any wait, so the phone gets its on-screen keyboard back.
    func stop()
}

/// keyboard-pairs.json, shared by both transports.
struct KeyboardPairsFile {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("iMirror/keyboard-pairs.json")
    }

    func load() -> KeyboardPairs {
        KeyboardPairs.decode(try? Data(contentsOf: url))
    }

    /// 0600: which phone is which is this user's business only.
    func save(_ pairs: KeyboardPairs) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try pairs.encode().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("iMirror: writing \(url.path) failed: \(error.localizedDescription)")
        }
    }
}

extension BLEKeyboard: KeyboardTransport {
    var kind: KeyboardTransportKind { .corebluetooth }

    func pair(udid: String, window: TimeInterval) async throws -> PairingOutcome {
        try await startPairing(udid: udid, window: window)
    }

    func type(_ steps: [KeyStep], to pair: KeyboardPair) async throws {
        guard let id = pair.central.flatMap(UUID.init(uuidString:)) else { throw BLEKeyboardError.notConnected }
        try await type(reports: steps, to: id)
    }

    /// Nothing to drop: the phone keeps its bond until removed there.
    func forget(_ pair: KeyboardPair) async throws {}
}
