// DongleSerialPort against a pseudo-terminal that plays the dongle, so the
// line I/O is checked with no ESP32 on USB.

import Darwin
import XCTest
@testable import iMirror
import iMirrorCore

final class SerialDongleTests: XCTestCase {
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private var path = ""

    override func setUpWithError() throws {
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw XCTSkip("no pty") }
        path = String(cString: name)
    }

    override func tearDown() {
        close(master); close(slave)
    }

    /// Reads one line the host wrote, as the dongle would.
    private func readLine(timeout: TimeInterval = 3) -> String {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var b: UInt8 = 0
        while Date() < deadline {
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0, read(master, &b, 1) == 1 else { continue }
            if b == 0x0A { break }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func reply(_ s: String) {
        _ = s.utf8CString.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count - 1) }
    }

    /// Plays the dongle on a background thread: sees one line, answers.
    private func dongle(_ answer: @escaping (String) -> String?) -> XCTestExpectation {
        let done = expectation(description: "dongle saw a line")
        DispatchQueue.global().async {
            let line = self.readLine()
            if let a = answer(line) { self.reply(a) }
            done.fulfill()
        }
        return done
    }

    func testHelloRoundTripSkipsLogLines() throws {
        let port = DongleSerialPort(path: path)
        try port.open()
        defer { port.close() }
        var seen = ""
        let done = dongle { seen = $0; return "# booted\r\nOK HELLO imirror-kbd 1 A0:F2:62:F3:6B:E2\r\n" }
        let r = try port.exchange(.hello)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(seen, "HELLO")
        XCTAssertEqual(DongleProtocol.hello(r)?.address, "a0:f2:62:f3:6b:e2")
    }

    func testSendLineArrivesWholeAsHex() throws {
        let port = DongleSerialPort(path: path)
        try port.open()
        defer { port.close() }
        let steps = HIDKeyboard.textReports("ab")!
        var seen = ""
        let done = dongle { seen = $0; return "OK SENT 4\n" }
        let r = try port.exchange(.send(slot: "s1", steps: steps))
        wait(for: [done], timeout: 3)
        XCTAssertTrue(DongleProtocol.sent(r, steps: 4))
        XCTAssertEqual(seen, "SEND s1 0000040000000000001e" + "0000000000000000001e"
                       + "0000050000000000001e" + "0000000000000000001e")
    }

    func testInputFromBeforeTheCommandIsDropped() throws {
        let port = DongleSerialPort(path: path)
        try port.open()
        defer { port.close() }
        reply("OK FORGOT s1\n")   // a late answer to an earlier command
        usleep(100_000)
        let done = dongle { _ in "ERR UNKNOWN_SLOT\n" }
        let r = try port.exchange(.forget(slot: "s1"))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(r.final, .err(code: "UNKNOWN_SLOT"))
    }

    func testASilentFirstHelloGetsOneMoreTry() throws {
        let port = DongleSerialPort(path: path)
        try port.open()
        defer { port.close() }
        var seen: [String] = []
        let done = expectation(description: "dongle saw two lines")
        DispatchQueue.global().async {
            seen.append(self.readLine())   // still booting: no answer
            seen.append(self.readLine())
            self.reply("OK HELLO imirror-kbd 1 a0:f2:62:f3:6b:e2\n")
            done.fulfill()
        }
        let r = DongleLink.hello(on: port)
        wait(for: [done], timeout: 6)
        XCTAssertEqual(seen, ["HELLO", "HELLO"])
        XCTAssertEqual(r.flatMap(DongleProtocol.hello)?.address, "a0:f2:62:f3:6b:e2")
    }

    func testSilenceIsNoReply() throws {
        let port = DongleSerialPort(path: path)
        try port.open()
        defer { port.close() }
        let done = dongle { _ in nil }
        XCTAssertThrowsError(try port.exchange(.hello)) { XCTAssertEqual($0 as? DongleError, .noReply) }
        wait(for: [done], timeout: 3)
    }
}
