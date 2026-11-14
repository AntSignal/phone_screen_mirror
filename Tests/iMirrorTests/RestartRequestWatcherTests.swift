import XCTest
@testable import iMirror
@testable import iMirrorCore

final class RestartRequestWatcherTests: XCTestCase {
    private var dir: URL!
    private let udid = "00008150-001928E01404401C"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imirror-req-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func put(_ name: String, _ text: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(text.utf8))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testScanDeliversAndDeletesARequest() {
        let w = RestartRequestWatcher(dir: dir)
        var got: [RestartRequest] = []
        w.onRequest = { got.append($0) }
        put("restart-\(udid).json", #"{"udid":"\#(udid)","requested_at":"2026-11-13T10:00:00Z","requested_by":"t"}"#)
        w.scan()
        XCTAssertEqual(got.map(\.udid), [udid])
        XCTAssertFalse(exists("restart-\(udid).json"))
        w.scan()
        XCTAssertEqual(got.count, 1, "a request is acted on once")
    }

    func testScanLeavesTempFilesAndFreshHalfWrittenOnes() {
        let w = RestartRequestWatcher(dir: dir)
        w.onRequest = { _ in XCTFail("nothing to deliver") }
        put("restart-\(udid).json.42.tmp", "{}")
        put("restart-\(udid).json", #"{"udid":"#)
        w.scan()
        XCTAssertTrue(exists("restart-\(udid).json.42.tmp"))
        XCTAssertTrue(exists("restart-\(udid).json"), "may still be mid-write")
        w.scan(now: Date().addingTimeInterval(11))
        XCTAssertFalse(exists("restart-\(udid).json"), "old junk is cleared")
    }

    func testTheFolderSourceHearsANewFile() {
        let w = RestartRequestWatcher(dir: dir)
        let heard = expectation(description: "request")
        w.onRequest = { _ in heard.fulfill() }
        w.start()
        defer { w.stop() }
        let body = #"{"udid":"\#(udid)","requested_at":"2026-11-13T10:00:00Z"}"#
        let tmp = dir.appendingPathComponent("restart-\(udid).json.1.tmp")
        try? Data(body.utf8).write(to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("restart-\(udid).json"))
        wait(for: [heard], timeout: 3)   // well under the 5 s scan
    }
}
