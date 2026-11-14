import XCTest
@testable import iMirror
@testable import iMirrorCore

final class EventLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imirror-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func event(_ n: Int) -> DeviceEvent {
        DeviceEvent(at: Date(), udid: "U", alias: "phone1", event: .restart, detail: "n\(n)")
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testAppendsOneLinePerEvent() {
        let log = EventLog(dir: dir)
        log.write(event(1)); log.write(event(2)); log.flush()
        XCTAssertEqual(lines(log.url).count, 2)
        XCTAssertTrue(lines(log.url)[1].contains(#""detail":"n2""#))
    }

    func testRotatesKeepingOneOldFile() {
        let log = EventLog(dir: dir, rotateAt: 300)
        for n in 0..<12 { log.write(event(n)) }
        log.flush()
        let old = log.url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path + ".1"))
        let size = (try? FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? NSNumber)?.intValue
        XCTAssertLessThanOrEqual(size ?? .max, 300)
        XCTAssertTrue(lines(log.url).last?.contains(#""detail":"n11""#) ?? false)
    }

    func testReadsTheExpectedResetNote() throws {
        let log = EventLog(dir: dir)
        let udid = "00008140-0006423002D3401C"
        XCTAssertFalse(log.resetIsExpected(udid: udid))
        let notes = dir.appendingPathComponent("expected-resets")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let until = DeviceEventCodec.timestamp(Date().addingTimeInterval(90))
        try Data(#"{"until":"\#(until)","by":"devicectl install"}"#.utf8)
            .write(to: notes.appendingPathComponent("\(udid).json"))
        XCTAssertTrue(log.resetIsExpected(udid: udid))
        XCTAssertFalse(log.resetIsExpected(udid: "00008150-001928E01404401C"))
    }
}
