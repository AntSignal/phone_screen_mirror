// EventLog — appends one JSON line per phone event to events.jsonl, and
// reads the expected-reset notes clients leave. The line format and the
// rules live in iMirrorCore/DeviceEvents.swift; this file only does I/O.
//
// Both files sit next to devices.json, so IMIRROR_DEVICES_FILE moves them too.

import Darwin
import Foundation
import iMirrorCore
import os

private let eventsLog = Logger(subsystem: "com.local.imirror", category: "events")

final class EventLog {
    static let shared = EventLog(dir: DeviceRegistryWriter().url.deletingLastPathComponent())

    let url: URL
    private let expectedDir: URL
    private let rotateAt: UInt64
    private let queue = DispatchQueue(label: "imirror.events")

    init(dir: URL, rotateAt: UInt64 = DeviceEventCodec.rotateAtBytes) {
        url = dir.appendingPathComponent("events.jsonl")
        expectedDir = dir.appendingPathComponent("expected-resets", isDirectory: true)
        self.rotateAt = rotateAt
    }

    /// Append off the caller's thread. Also mirrored to the unified log in
    /// the clear: events never hold secrets, and `<private>` lines told us nothing.
    func write(_ event: DeviceEvent) {
        let line = DeviceEventCodec.line(event)
        let text = String(decoding: line.dropLast(), as: UTF8.self)
        eventsLog.notice("\(text, privacy: .public)")
        queue.async { [url, rotateAt] in Self.append(line, to: url, rotateAt: rotateAt) }
    }

    /// Wait for queued writes. Tests only.
    func flush() { queue.sync {} }

    /// Has a client said this phone's next USB reset is its own doing?
    func resetIsExpected(udid: String, now: Date = Date()) -> Bool {
        guard let name = ExpectedReset.fileName(udid: udid) else { return false }
        return ExpectedReset.holds(try? Data(contentsOf: expectedDir.appendingPathComponent(name)), now: now)
    }

    private static func append(_ line: Data, to url: URL, rotateAt: UInt64) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if DeviceEventCodec.shouldRotate(currentSize: size, adding: line.count, limit: rotateAt) {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: line)
    }
}

enum ProcessIdentity {
    /// This app's p_uniqueid, which the kernel never reuses within a boot.
    /// PROC_PIDUNIQIDENTIFIERINFO (flavor 17) has no Swift struct: 56 bytes,
    /// p_uniqueid at offset 16. The MCP server reads the same field.
    static let ownUniqueID: UInt64? = {
        var raw = [UInt8](repeating: 0, count: 56)
        let n = raw.withUnsafeMutableBytes { proc_pidinfo(getpid(), 17, 0, $0.baseAddress, 56) }
        guard n == 56 else { return nil }
        return raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
    }()
}
