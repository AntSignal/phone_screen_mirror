// SerialDongleKeyboard — types through the ESP32-S3 keyboard dongle on USB
// (serial protocol v1, iMirrorCore/DongleProtocol.swift). It only moves
// lines; the dongle does the Bluetooth.
//
// The port is opened per job and closed after, so a replugged dongle is
// found again and the firmware can be flashed between jobs. While a job
// runs the port is exclusive, so a serial monitor cannot eat a reply.
//
// SEND lines may spell a passcode: only counts are logged, and the line
// bytes are zeroed after writing (Swift may still leave copies).

import Darwin
import Foundation
import IOKit
import IOKit.serial
import iMirrorCore

enum DongleError: Error, Equatable {
    /// No USB serial port answered HELLO as a v1 dongle.
    case notFound
    /// No final line before the command's timeout.
    case noReply
    /// The port went away mid-command (unplugged, reset).
    case unplugged
    /// The dongle answered, but not with the success asked for.
    case failed(KeyboardFailure)
}

/// The dongle's serial port. Blocking I/O: DongleLink's queue only.
final class DongleSerialPort {
    let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }
    deinit { close() }

    /// Raw 8N1 at 115200 (the S3's USB port ignores the rate).
    func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw DongleError.notFound }
        // Exclusive: other opens fail until we close.
        guard ioctl(fd, TIOCEXCL) == 0 else { close(); throw DongleError.notFound }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // Keep DTR/RTS up on close. RTS up with DTR down holds the S3 in reset.
        t.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { close(); throw DongleError.notFound }
        // Both lines up in one change: never through the reset state.
        var lines = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIS, &lines)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Writes one command and reads until its final line. Input left from
    /// before (logs, a late reply) is dropped first.
    func exchange(_ command: DongleCommand) throws -> DongleReply {
        guard fd >= 0 else { throw DongleError.unplugged }
        tcflush(fd, TCIFLUSH)
        let deadline = Date().addingTimeInterval(DongleProtocol.timeout(for: command))
        var line = command.line
        defer { SecretsFile.zero(&line) }
        try writeAll(line, deadline: deadline)
        var reader = DongleReplyReader(for: command)
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            try waitFor(Int16(POLLIN), deadline: deadline)
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            // 0 is end of file: the device went away.
            guard n > 0 else { throw DongleError.unplugged }
            let out = reader.feed(Array(buf[0..<n]))
            // Logs never hold typed text (protocol rule); clipped anyway.
            out.logs.forEach { NSLog("iMirror: dongle # \(String($0.prefix(200)))") }
            if let reply = out.reply { return reply }
        }
    }

    private func writeAll(_ bytes: [UInt8], deadline: Date) throws {
        var done = 0
        while done < bytes.count {
            let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { done += n; continue }
            guard n < 0, errno == EAGAIN || errno == EINTR else { throw DongleError.unplugged }
            try waitFor(Int16(POLLOUT), deadline: deadline)
        }
    }

    /// Returns once `events` is ready; throws on timeout or hang-up.
    private func waitFor(_ events: Int16, deadline: Date) throws {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw DongleError.noReply }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
            if r < 0 { if errno == EINTR { continue } else { throw DongleError.unplugged } }
            if p.revents & events != 0 { return }
            if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw DongleError.unplugged }
        }
    }
}

/// Finds the dongle and runs jobs on it, one at a time, off the main thread.
final class DongleLink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.imirror.dongle")
    /// Path → when it may be tried again after failing HELLO. Queue only.
    private var skipUntil: [String: Date] = [:]
    /// Another Espressif board may be on USB; don't HELLO it every job.
    static let skipSec: TimeInterval = 30

    /// Every /dev/cu.usbmodem* whose USB device has Espressif's vendor id.
    static func calloutPaths() -> [String] {
        let match = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        match[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [String] = []
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let path = IORegistryEntryCreateCFProperty(s, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            // idVendor sits on the USB device, a few parents up.
            let vid = IORegistryEntrySearchCFProperty(s, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                                                      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if let path, path.hasPrefix("/dev/cu.usbmodem"), (vid as? Int) == DongleProtocol.vendorID {
                out.append(path)
            }
        }
        return out.sorted()
    }

    /// Opens the dongle, checks HELLO, runs `body`, closes. Throws
    /// `.notFound` when no port answers as a v1 dongle.
    func run<T: Sendable>(_ body: @escaping @Sendable (DongleSerialPort, DongleHello) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try self.withOpenPort(body) })
            }
        }
    }

    private func withOpenPort<T>(_ body: (DongleSerialPort, DongleHello) throws -> T) throws -> T {
        let now = Date()
        for path in Self.calloutPaths() where (skipUntil[path] ?? .distantPast) <= now {
            let port = DongleSerialPort(path: path)
            defer { port.close() }
            guard (try? port.open()) != nil, let reply = Self.hello(on: port) else {
                skipUntil[path] = now.addingTimeInterval(Self.skipSec)
                continue
            }
            // Still running a command we gave up on: it is the dongle.
            if reply.final == .err(code: "BUSY") { throw DongleError.failed(.busy) }
            guard let hello = DongleProtocol.hello(reply) else {
                skipUntil[path] = now.addingTimeInterval(Self.skipSec)
                continue
            }
            skipUntil[path] = nil
            return try body(port, hello)
        }
        throw DongleError.notFound
    }

    /// USB comes up before the firmware, so a dongle plugged in a moment
    /// ago can miss the first HELLO while it boots. A silent port gets one
    /// more try; without it the dongle reads as absent for `skipSec`.
    static func hello(on port: DongleSerialPort) -> DongleReply? {
        for _ in 0..<2 {
            do { return try port.exchange(.hello) } catch DongleError.noReply { continue } catch { return nil }
        }
        return nil
    }
}

@MainActor
final class SerialDongleKeyboard: KeyboardTransport {
    enum State: Equatable {
        case unknown, notFound
        case connected(address: String)
    }

    let kind = KeyboardTransportKind.dongle
    let pairsFile: KeyboardPairsFile
    private let link = DongleLink()
    private(set) var state: State = .unknown { didSet { if state != oldValue { onStateChange?() } } }
    var onStateChange: (() -> Void)?
    private var lastPaths: [String]?
    private var timer: Timer?

    init(pairsFile: KeyboardPairsFile) { self.pairsFile = pairsFile }

    /// Checks USB every 5 s; says HELLO only when the set of Espressif
    /// ports changes, so an idle dongle's port stays closed.
    func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUSB() }
        }
        checkUSB()
    }

    private func checkUSB() {
        let paths = DongleLink.calloutPaths()
        guard paths != lastPaths else { return }
        lastPaths = paths
        if paths.isEmpty { state = .notFound; return }
        Task { _ = await available() }
    }

    /// True when a dongle answers HELLO now. Updates `state`.
    func available() async -> Bool {
        do {
            let hello = try await link.run { _, hello in hello }
            state = .connected(address: hello.address)
            return true
        } catch {
            state = .notFound
            return false
        }
    }

    func pair(udid: String, window: TimeInterval) async throws -> PairingOutcome {
        guard let slot = DongleProtocol.slot(udid: udid) else { throw DongleError.failed(.badRequest) }
        let seconds = min(max(Int(window), DongleProtocol.pairSeconds.lowerBound), DongleProtocol.pairSeconds.upperBound)
        let reply = try await exchange(.pair(slot: slot, seconds: seconds))
        guard let outcome = DongleProtocol.pairOutcome(reply, slot: slot) else {
            throw DongleError.failed(DongleProtocol.failure(reply))
        }
        if case .paired(let peer) = outcome {
            var pairs = pairsFile.load()
            pairs.record(udid: udid, slot: slot, peer: peer, at: Date())
            pairsFile.save(pairs)
        }
        NSLog("iMirror: dongle pairing for \(udid) ended: \(BLEKeyboard.describe(outcome))")
        return outcome
    }

    /// One SEND per chunk; a long text may reconnect between chunks.
    /// `beforeFirstKey` is never called: the first key leaves inside a
    /// SEND, after a reconnect of up to 15 s. Callers bound its age from
    /// the SEND's timing instead (FirstKeyAge).
    /// Never logs the steps: they may spell a passcode.
    func type(_ steps: [KeyStep], to pair: KeyboardPair, beforeFirstKey: FirstKeyCheck?) async throws {
        guard let slot = pair.slot else { throw DongleError.failed(.notPaired) }
        let sends = try await runJob { port, _ in
            // Built here so the only copy is wiped here.
            guard var chunks = DongleProtocol.sendChunks(steps) else { throw DongleError.failed(.sendFailed) }
            defer { for i in chunks.indices { HIDKeyboard.wipe(&chunks[i]) } }
            for chunk in chunks {
                let reply = try port.exchange(.send(slot: slot, steps: chunk))
                guard DongleProtocol.sent(reply, steps: chunk.count) else {
                    throw DongleError.failed(DongleProtocol.failure(reply))
                }
            }
            return chunks.count
        }
        NSLog("iMirror: dongle sent \(steps.count) steps in \(sends) SEND(s)")
    }

    func forget(_ pair: KeyboardPair) async throws {
        guard let slot = pair.slot else { return }
        let reply = try await exchange(.forget(slot: slot))
        guard DongleProtocol.forgot(reply, slot: slot) else { throw DongleError.failed(DongleProtocol.failure(reply)) }
    }

    /// The dongle goes quiet by itself after each command.
    func stop() {}

    private func exchange(_ command: DongleCommand) async throws -> DongleReply {
        NSLog("iMirror: dongle \(command.description)")
        return try await runJob { port, _ in try port.exchange(command) }
    }

    /// Runs on the link and keeps `state` true to what happened.
    private func runJob<T: Sendable>(_ body: @escaping @Sendable (DongleSerialPort, DongleHello) throws -> T)
        async throws -> T {
        do {
            let (value, address) = try await link.run { port, hello in (try body(port, hello), hello.address) }
            state = .connected(address: address)
            return value
        } catch DongleError.notFound {
            state = .notFound
            throw DongleError.notFound
        }
    }
}
