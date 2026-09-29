// Tests for the multi-phone plumbing that isn't pure enough for iMirrorCore:
// go-ios command lines, the per-phone sweep pattern (checked with the real ERE
// engine pkill uses), the port-in-use check, and the device file writer.

import Darwin
import Network
import XCTest
import iMirrorCore
@testable import iMirror

final class GoIOSCommandTests: XCTestCase {
    private let a = "00008140-0006423002D3401C"
    private let bin = "/Applications/iMirror.app/Contents/Resources/ios"

    func testEveryPerPhoneCommandNamesItsPhoneFirst() {
        XCTAssertEqual(GoIOS.runwdaArgs(udid: a),
                       ["runwda", "--udid=\(a)",
                        "--bundleid=com.local.imirror.WebDriverAgentRunner.xctrunner",
                        "--testrunnerbundleid=com.local.imirror.WebDriverAgentRunner.xctrunner",
                        "--xctestconfig=WebDriverAgentRunner.xctest"])
        XCTAssertEqual(GoIOS.forwardArgs(udid: a, hostPort: 8111, devicePort: 8100),
                       ["forward", "--udid=\(a)", "8111", "8100"])
        XCTAssertEqual(GoIOS.appsListArgs(udid: a), ["apps", "--list", "--udid=\(a)"])
        XCTAssertEqual(GoIOS.installArgs(udid: a, ipa: "/x/WDA.ipa"),
                       ["install", "--udid=\(a)", "--path=/x/WDA.ipa"])
    }

    /// Match a command line the way `pkill -f` does: POSIX ERE on the whole
    /// argument string.
    private func ereMatches(_ pattern: String, _ line: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-qE", pattern]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        try! p.run()
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
        try! input.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func testSweepTakesOnlyThisPhonesRunwdaAndForwards() {
        let pattern = GoIOS.sweepPattern(bin: bin, udid: a)
        let mine = ([bin] + GoIOS.runwdaArgs(udid: a)).joined(separator: " ")
        let myForward = ([bin] + GoIOS.forwardArgs(udid: a, hostPort: 8101, devicePort: 8100)).joined(separator: " ")
        XCTAssertTrue(ereMatches(pattern, mine))
        XCTAssertTrue(ereMatches(pattern, myForward))

        let other = "00008150-001928E01404401C"
        XCTAssertFalse(ereMatches(pattern, ([bin] + GoIOS.runwdaArgs(udid: other)).joined(separator: " ")))
        XCTAssertFalse(ereMatches(pattern, "\(bin) forward --udid=\(a)X 8111 8100"))   // a longer UDID
        XCTAssertFalse(ereMatches(pattern, "\(bin) tunnel start --userspace"))         // the shared tunnel
        XCTAssertFalse(ereMatches(pattern, "/other/checkout/ios runwda --udid=\(a) x"))  // another app's go-ios
        XCTAssertFalse(ereMatches(pattern, "\(bin) runwda --bundleid=x"))              // old, udid-less chain
    }

    func testAppStartSweepCoversUdidLessOrphans() {
        let patterns = GoIOS.sweepAllPatterns(bin: bin)
        for line in ["\(bin) tunnel start --userspace", "\(bin) runwda --bundleid=x", "\(bin) forward 8101 8100",
                     ([bin] + GoIOS.runwdaArgs(udid: a)).joined(separator: " ")] {
            XCTAssertTrue(patterns.contains { ereMatches($0, line) }, line)
        }
        XCTAssertFalse(patterns.contains { ereMatches($0, "/other/ios tunnel start") })
        XCTAssertTrue(ereMatches(GoIOS.tunnelSweepPattern(bin: bin), "\(bin) tunnel start --userspace"))
        XCTAssertFalse(ereMatches(GoIOS.tunnelSweepPattern(bin: bin), "\(bin) runwda --udid=\(a)"))
    }

    func testPathMetacharactersAreEscaped() {
        let odd = "/Users/x/My Apps (old)/iMirror.app/Contents/Resources/ios"
        XCTAssertTrue(ereMatches(GoIOS.sweepPattern(bin: odd, udid: a),
                                 ([odd] + GoIOS.runwdaArgs(udid: a)).joined(separator: " ")))
        XCTAssertFalse(ereMatches(GoIOS.sweepPattern(bin: "/a.b/ios", udid: a), "/aXb/ios runwda --udid=\(a) x"))
    }
}

final class PortCheckTests: XCTestCase {
    func testAListeningPortIsNotFreeAndAClosedOneIs() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // any free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        XCTAssertFalse(ChainManager.portIsFree(port))
        close(fd)
        XCTAssertTrue(ChainManager.portIsFree(port))
    }
}

final class DeviceRegistryWriterTests: XCTestCase {
    private var dir: URL!
    private var child: Process?

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMirrorTests-reg-\(UUID().uuidString)", isDirectory: true)
        setenv("IMIRROR_DEVICES_FILE", dir.appendingPathComponent("devices.json").path, 1)
    }

    override func tearDown() {
        unsetenv("IMIRROR_DEVICES_FILE")
        child?.terminate()
        child?.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func file(owner: Int32) -> DeviceRegistryFile {
        DeviceRegistryFile(ownerPid: owner, appVersion: "t", updatedAt: "2026-09-28T00:00:00Z", goios: nil,
                           devices: [RegisteredDevice(udid: "U1", alias: "phone1", kind: .device,
                                                      wdaURL: "http://127.0.0.1:8100", state: .ready)])
    }

    func testWritesTheFileAndRemovesOnlyItsOwn() throws {
        let writer = DeviceRegistryWriter()
        XCTAssertEqual(writer.url.deletingLastPathComponent(), dir)
        writer.write(file(owner: getpid()))
        let back = try DeviceRegistryCodec.decode(Data(contentsOf: writer.url))
        XCTAssertEqual(back.devices.map(\.alias), ["phone1"])
        XCTAssertNil(writer.foreignOwner(), "our own file is not someone else's")
        writer.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
    }

    func testAnotherLiveInstancesFileIsRespected() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        child = sleeper
        let writer = DeviceRegistryWriter()
        writer.write(file(owner: sleeper.processIdentifier))
        XCTAssertEqual(writer.foreignOwner(), sleeper.processIdentifier)
        writer.remove()                                     // not ours: must stay
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.url.path))
        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertNil(writer.foreignOwner(), "a dead owner's file is stale, not a live instance")
    }
}
