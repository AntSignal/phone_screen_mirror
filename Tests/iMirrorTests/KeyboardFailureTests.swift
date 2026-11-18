import XCTest
@testable import iMirror
import iMirrorCore

/// The event `reason` each transport's errors are logged with.
final class KeyboardFailureTests: XCTestCase {
    func testFailureNames() {
        XCTAssertEqual(KeyboardControl.failure(DongleError.notFound), .dongleUnavailable)
        XCTAssertEqual(KeyboardControl.failure(DongleError.noReply), .dongleError)
        XCTAssertEqual(KeyboardControl.failure(DongleError.unplugged), .dongleError)
        XCTAssertEqual(KeyboardControl.failure(DongleError.failed(.notConnected)), .notConnected)
        XCTAssertEqual(KeyboardControl.failure(BLEKeyboardError.busy), .busy)
    }
}
