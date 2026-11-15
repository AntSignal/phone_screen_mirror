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

    func testScanDeliversKeyboardRequestsAndRefusalsApart() {
        let w = RestartRequestWatcher(dir: dir)
        var restarts = 0
        var got: [KeyboardRequestFile.Read] = []
        w.onRequest = { _ in restarts += 1 }
        w.onKeyboard = { got.append($0) }
        let at = ISO8601DateFormatter().string(from: Date())
        put("keyboard-\(udid).json", #"{"udid":"\#(udid)","requested_at":"\#(at)","action":"pair"}"#)
        put("keyboard-A-1.json", #"{"udid":"A-1","requested_at":"\#(at)","action":"passcode"}"#)
        put("keyboard-B-2.json", #"{"udid":"B-2"#)
        w.scan()
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(got.count, 2)
        guard case .request(let r)? = got.first(where: { if case .request = $0 { return true }; return false }) else {
            return XCTFail("pair not delivered")
        }
        XCTAssertEqual(r.action, .pair)
        XCTAssertTrue(got.contains(.refused(udid: "A-1", .unknownAction)))
        XCTAssertFalse(exists("keyboard-\(udid).json"))
        XCTAssertFalse(exists("keyboard-A-1.json"), "a refused request is gone too")
        XCTAssertTrue(exists("keyboard-B-2.json"), "may still be mid-write")
        w.scan(now: Date().addingTimeInterval(11))
        XCTAssertFalse(exists("keyboard-B-2.json"))
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
