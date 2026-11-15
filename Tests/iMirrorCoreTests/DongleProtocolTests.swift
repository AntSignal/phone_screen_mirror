import XCTest
@testable import iMirrorCore

final class DongleProtocolTests: XCTestCase {
    private let slot = "000081400006423002d3401c"

    private func text(_ c: DongleCommand) -> String { String(decoding: c.line, as: UTF8.self) }

    func testPlainCommandsAreOneLineEach() {
        XCTAssertEqual(text(.hello), "HELLO\n")
        XCTAssertEqual(text(.status), "STATUS\n")
        XCTAssertEqual(text(.bonds), "BONDS\n")
        XCTAssertEqual(text(.disconnect), "DISCONNECT\n")
        XCTAssertEqual(text(.pair(slot: slot, seconds: 120)), "PAIR \(slot) 120\n")
        XCTAssertEqual(text(.forget(slot: slot)), "FORGET \(slot)\n")
    }

    func testOkWordForEachCommand() {
        let cmds: [DongleCommand] = [.hello, .status, .bonds, .disconnect, .pair(slot: slot, seconds: 10),
                                     .forget(slot: slot), .send(slot: slot, steps: [])]
        XCTAssertEqual(cmds.map(\.okWord), ["HELLO", "STATUS", "BONDS", "DISCONNECTED", "PAIRED", "FORGOT", "SENT"])
    }

    func testTimeouts() {
        XCTAssertEqual(DongleProtocol.timeout(for: .hello), 2)
        XCTAssertEqual(DongleProtocol.timeout(for: .send(slot: slot, steps: [])), 30)
        let typing = HIDKeyboard.textReports("ab")!   // 4 steps of 30 ms
        XCTAssertEqual(DongleProtocol.timeout(for: .send(slot: slot, steps: typing)), 30.12, accuracy: 0.001)
        let slow = Array(repeating: KeyStep(report: HIDKeyboard.releaseReport, delayAfterMs: 2000), count: 128)
        XCTAssertEqual(DongleProtocol.timeout(for: .send(slot: slot, steps: slow)), 286)
        XCTAssertEqual(DongleProtocol.timeout(for: .pair(slot: slot, seconds: 120)), 130)
        XCTAssertEqual(DongleProtocol.timeout(for: .forget(slot: slot)), 5)
    }

    // MARK: - Slots

    func testSlotIsTheUDIDLowerCasedWithoutDashes() {
        XCTAssertEqual(DongleProtocol.slot(udid: "00008140-0006423002D3401C"), slot)
        XCTAssertEqual(DongleProtocol.slot(udid: String(repeating: "AB", count: 20)),
                       String(repeating: "ab", count: 16))
        XCTAssertNil(DongleProtocol.slot(udid: ""))
        XCTAssertNil(DongleProtocol.slot(udid: "../x"))
        XCTAssertNil(DongleProtocol.slot(udid: "----"))
    }

    func testSlotNameRule() {
        XCTAssertTrue(DongleProtocol.isValidSlot("a-1"))
        XCTAssertTrue(DongleProtocol.isValidSlot(String(repeating: "a", count: 32)))
        XCTAssertFalse(DongleProtocol.isValidSlot(String(repeating: "a", count: 33)))
        XCTAssertFalse(DongleProtocol.isValidSlot(""))
        XCTAssertFalse(DongleProtocol.isValidSlot("A"))
        XCTAssertFalse(DongleProtocol.isValidSlot("a b"))
        XCTAssertFalse(DongleProtocol.isValidSlot("é"))
    }

    // MARK: - SEND framing

    func testSendHexIsReportThenBigEndianDelay() {
        let steps = [KeyStep(report: [0x02, 0, 0x04, 0, 0, 0, 0, 0], delayAfterMs: 30),
                     KeyStep(report: HIDKeyboard.releaseReport, delayAfterMs: 0x0258)]
        XCTAssertEqual(text(.send(slot: slot, steps: steps)),
                       "SEND \(slot) 0200040000000000001e" + "00000000000000000258\n")
    }

    func testChunksAreAtMost128AndEndOnAKeyUp() {
        let a = HIDKeyboard.stroke(for: "a")!
        let steps = HIDKeyboard.sequence(Array(repeating: a, count: 100))   // 200 steps
        let chunks = DongleProtocol.sendChunks(steps)!
        XCTAssertEqual(chunks.map(\.count), [128, 72])
        XCTAssertEqual(Array(chunks.joined()), steps)
        for c in chunks { XCTAssertEqual(c.last?.report, HIDKeyboard.releaseReport) }
        // An odd cap backs off to the last key-up.
        XCTAssertEqual(DongleProtocol.sendChunks(steps, max: 5)!.first?.count, 4)
    }

    func testChunksWithNoKeyUpStillSplitAtTheCap() {
        let down = KeyStep(report: [0, 0, 4, 0, 0, 0, 0, 0], delayAfterMs: 1)
        XCTAssertEqual(DongleProtocol.sendChunks(Array(repeating: down, count: 3), max: 2)!.map(\.count), [2, 1])
    }

    func testChunksRefuseBadStepsWhole() {
        let ok = KeyStep(report: HIDKeyboard.releaseReport, delayAfterMs: 0)
        XCTAssertNil(DongleProtocol.sendChunks([]))
        XCTAssertNil(DongleProtocol.sendChunks([ok, KeyStep(report: [0, 0], delayAfterMs: 0)]))
        XCTAssertNil(DongleProtocol.sendChunks([ok, KeyStep(report: HIDKeyboard.releaseReport, delayAfterMs: 2001)]))
        XCTAssertNil(DongleProtocol.sendChunks([KeyStep(report: HIDKeyboard.releaseReport, delayAfterMs: -1)]))
        XCTAssertNotNil(DongleProtocol.sendChunks([KeyStep(report: HIDKeyboard.releaseReport, delayAfterMs: 2000)]))
    }

    func testPasscodeStepsFitOneSend() {
        let steps = HIDKeyboard.wakeThenPasscode(ascii: Array("123456".utf8))!
        XCTAssertEqual(DongleProtocol.sendChunks(steps)?.count, 1)
    }

    // MARK: - Nothing typed reaches a log

    func testSendDescriptionNeverHoldsThePayload() {
        let secret = HIDKeyboard.wakeThenPasscode(ascii: Array("hunter2".utf8))!
        let cmd = DongleCommand.send(slot: slot, steps: secret)
        let hex = String(decoding: cmd.line, as: UTF8.self).split(separator: " ")[2]
            .trimmingCharacters(in: .newlines)
        XCTAssertEqual(cmd.description, "SEND \(slot) <\(secret.count) steps>")
        for shown in [cmd.description, "\(cmd)", String(describing: cmd), String(reflecting: cmd),
                      "\(DongleCommand.pair(slot: slot, seconds: 10))"] {
            XCTAssertFalse(shown.contains(hex), shown)
            // Not even one report's hex (h = usage 0x0b).
            XCTAssertFalse(shown.contains("000b"), shown)
            XCTAssertFalse(shown.contains("hunter"), shown)
        }
    }

    func testNonSendDescriptionsAreTheLine() {
        XCTAssertEqual(DongleCommand.pair(slot: slot, seconds: 60).description, "PAIR \(slot) 60")
        XCTAssertEqual(DongleCommand.hello.description, "HELLO")
    }

    // MARK: - Replies

    func testParseLines() {
        XCTAssertEqual(DongleProtocol.parse("# advertising"), .log("advertising"))
        XCTAssertEqual(DongleProtocol.parse("OK STATUS bonds=1 conns=0 adv=0"),
                       .ok(word: "STATUS", args: ["bonds=1", "conns=0", "adv=0"]))
        XCTAssertEqual(DongleProtocol.parse("ERR BUSY"), .err(code: "BUSY"))
        XCTAssertEqual(DongleProtocol.parse("BOND \(slot) 4A:3B:2C:1D:0E:FF"),
                       .bond(slot: slot, peer: "4a:3b:2c:1d:0e:ff"))
        XCTAssertEqual(DongleProtocol.parse("BOND \(slot) nonsense"), .other)
        XCTAssertEqual(DongleProtocol.parse("OK"), .other)
        XCTAssertEqual(DongleProtocol.parse(""), .other)
        XCTAssertEqual(DongleProtocol.parse("ESP-ROM:esp32s3-20210327"), .other)
    }

    func testAddress() {
        XCTAssertEqual(DongleProtocol.address("A0:F2:62:F3:6B:E0"), "a0:f2:62:f3:6b:e0")
        XCTAssertNil(DongleProtocol.address("a0:f2:62:f3:6b"))
        XCTAssertNil(DongleProtocol.address("a0:f2:62:f3:6b:eg"))
        XCTAssertNil(DongleProtocol.address("a0:f2:62:f3:6b:e00"))
    }

    func testHelloAcceptsOnlyAV1Dongle() {
        let good = DongleReply(final: .ok(word: "HELLO", args: ["imirror-kbd", "1", "a0:f2:62:f3:6b:e2"]))
        XCTAssertEqual(DongleProtocol.hello(good), DongleHello(version: 1, address: "a0:f2:62:f3:6b:e2"))
        for args in [["imirror-kbd", "2", "a0:f2:62:f3:6b:e2"], ["other", "1", "a0:f2:62:f3:6b:e2"],
                     ["imirror-kbd", "1"], ["imirror-kbd", "1", "x"]] {
            XCTAssertNil(DongleProtocol.hello(DongleReply(final: .ok(word: "HELLO", args: args))), "\(args)")
        }
        XCTAssertNil(DongleProtocol.hello(DongleReply(final: .err(code: "BUSY"))))
    }

    func testReaderCollectsBondsAndSkipsLogsAndNoise() {
        var r = DongleReplyReader(for: .bonds)
        var out = r.feed(Array("# boot\r\nBOND a 01:02:03:04:05:06\r\nBO".utf8))
        XCTAssertNil(out.reply)
        XCTAssertEqual(out.logs, ["boot"])
        out = r.feed(Array("ND b 0a:0b:0c:0d:0e:0f\nOK BONDS 2\n".utf8))
        XCTAssertEqual(out.reply, DongleReply(final: .ok(word: "BONDS", args: ["2"]),
                                              bonds: [DongleBond(slot: "a", peer: "01:02:03:04:05:06"),
                                                      DongleBond(slot: "b", peer: "0a:0b:0c:0d:0e:0f")]))
    }

    func testReaderSkipsAnotherCommandsOk() {
        var r = DongleReplyReader(for: .forget(slot: slot))
        XCTAssertNil(r.feed(Array("OK PAIRED x 01:02:03:04:05:06\n".utf8)).reply)
        XCTAssertEqual(r.feed(Array("OK FORGOT \(slot)\n".utf8)).reply,
                       DongleReply(final: .ok(word: "FORGOT", args: [slot])))
    }

    func testReaderDropsOverlongLines() {
        var r = DongleReplyReader(for: .hello)
        let junk = [UInt8](repeating: 0x41, count: 600) + Array(" OK HELLO\n".utf8)
        XCTAssertNil(r.feed(junk).reply)
        XCTAssertEqual(r.feed(Array("ERR BUSY\n".utf8)).reply, DongleReply(final: .err(code: "BUSY")))
    }

    func testOutcomes() {
        let paired = DongleReply(final: .ok(word: "PAIRED", args: [slot, "01:02:03:04:05:06"]))
        XCTAssertEqual(DongleProtocol.pairOutcome(paired, slot: slot), .paired(central: "01:02:03:04:05:06"))
        XCTAssertNil(DongleProtocol.pairOutcome(paired, slot: "other"))
        XCTAssertEqual(DongleProtocol.pairOutcome(DongleReply(final: .err(code: "AMBIGUOUS")), slot: slot),
                       .ambiguous(count: 2))
        XCTAssertEqual(DongleProtocol.pairOutcome(DongleReply(final: .err(code: "TIMEOUT")), slot: slot), PairingOutcome.none)
        XCTAssertNil(DongleProtocol.pairOutcome(DongleReply(final: .err(code: "BUSY")), slot: slot))

        XCTAssertTrue(DongleProtocol.sent(DongleReply(final: .ok(word: "SENT", args: ["14"])), steps: 14))
        XCTAssertFalse(DongleProtocol.sent(DongleReply(final: .ok(word: "SENT", args: ["13"])), steps: 14))
        XCTAssertTrue(DongleProtocol.forgot(DongleReply(final: .ok(word: "FORGOT", args: [slot])), slot: slot))
        XCTAssertTrue(DongleProtocol.forgot(DongleReply(final: .err(code: "UNKNOWN_SLOT")), slot: slot))

        let f = { DongleProtocol.failure(DongleReply(final: .err(code: $0))) }
        XCTAssertEqual(f("BUSY"), .busy)
        XCTAssertEqual(f("NOT_CONNECTED"), .notConnected)
        XCTAssertEqual(f("UNKNOWN_SLOT"), .notPaired)
        XCTAssertEqual(f("BADARG"), .dongleError)
        XCTAssertEqual(f("WHAT"), .dongleError)
    }
}

final class KeyboardEventTransportTests: XCTestCase {
    func testKeyboardEventCarriesTransport() {
        let e = DeviceEvent.keyboard(at: Date(timeIntervalSince1970: 0), udid: "U", alias: "p",
                                     .typedTest, chars: 5, transport: .dongle)
        let line = String(decoding: DeviceEventCodec.line(e), as: UTF8.self)
        XCTAssertTrue(line.contains("\"transport\":\"dongle\""), line)
        let old = DeviceEvent.keyboard(at: Date(timeIntervalSince1970: 0), udid: "U", alias: "p", .forgotten)
        XCTAssertFalse(String(decoding: DeviceEventCodec.line(old), as: UTF8.self).contains("transport"))
    }
}
