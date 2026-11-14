import CoreGraphics
import XCTest
@testable import iMirrorCore

/// A rotation must drop the cached window size (videoShapeChanged).
final class VideoShapeTests: XCTestCase {
    func testOnlyARealChangeOfShapeCounts() {
        let portrait = CGSize(width: 1170, height: 2532), landscape = CGSize(width: 2532, height: 1170)
        XCTAssertFalse(videoShapeChanged(previous: nil, current: portrait), "first frame")
        XCTAssertFalse(videoShapeChanged(previous: portrait, current: portrait))
        XCTAssertTrue(videoShapeChanged(previous: portrait, current: landscape))
        XCTAssertTrue(videoShapeChanged(previous: CGSize(width: 2100, height: 1800),
                                        current: CGSize(width: 1800, height: 2100)))
    }
}
