import CoreGraphics
import XCTest
@testable import LiveWallCore

final class ReframeTests: XCTestCase {
    private let proLight = CGSize(width: 3472, height: 2266)
    private let duo = 3222.0 / 2266.0                       // iPhone Duo inner screen used landscape

    func testSqueezeReproducesTheApprovedH2Sizes() {
        let plan = Reframe.plan(sourceSize: proLight, aspect: duo, mode: .squeeze)
        XCTAssertEqual(plan.coverSize.width, 3222)
        XCTAssertEqual(plan.coverSize.height, 2266)
        XCTAssertEqual(plan.videoSize.width, 2176)
        XCTAssertEqual(plan.videoSize.height, 1530)
        XCTAssertEqual(plan.cropRect, CGRect(origin: .zero, size: proLight))     // squeeze uses the whole picture
    }

    func testCropCutsTheTargetAspectAtTheFocus() {
        let plan = Reframe.plan(sourceSize: proLight, aspect: duo, mode: .crop, focus: CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(plan.cropRect.size, CGSize(width: 3222, height: 2266))
        XCTAssertEqual(plan.cropRect.minX, 0)
        let right = Reframe.plan(sourceSize: proLight, aspect: duo, mode: .crop, focus: CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(right.cropRect.maxX, 3472)
    }

    func testVideoLongSideIsCappedAndEven() {
        for aspect in [0.46, 0.75, 1.0, 1.42, 1.78, 2.17] {
            for mode in ReframeMode.allCases {
                let plan = Reframe.plan(sourceSize: CGSize(width: 3840, height: 2160), aspect: aspect, mode: mode)
                XCTAssertLessThanOrEqual(max(plan.videoSize.width, plan.videoSize.height), 2176, "aspect \(aspect)")
                XCTAssertEqual(plan.videoSize.width % 2, 0)
                XCTAssertEqual(plan.videoSize.height % 2, 0)
            }
        }
    }

    /// Round 37 (11-14): portrait video 944x2048 and 1002x2176 would not enable motion, 884x1920 did.
    func testPortraitVideoIsCappedAt1920ButLandscapeKeeps2176() {
        let proLight = CGSize(width: 3472, height: 2266)
        let portrait = Reframe.plan(sourceSize: proLight, aspect: 1179.0 / 2556.0, mode: .crop)
        XCTAssertEqual(portrait.videoSize.height, 1920)
        let landscape = Reframe.plan(sourceSize: proLight, aspect: 3222.0 / 2266.0, mode: .squeeze)
        XCTAssertEqual(landscape.videoSize.width, 2176)
        // experiments can still override the cap
        XCTAssertEqual(Reframe.plan(sourceSize: proLight, aspect: 1179.0 / 2556.0, mode: .crop, maxVideoLongSide: 2048).videoSize.height, 2048)
    }

    func testSmallSourceIsNeverEnlarged() {
        let plan = Reframe.plan(sourceSize: CGSize(width: 1280, height: 720), aspect: 1.5, mode: .squeeze)
        XCTAssertLessThanOrEqual(plan.coverSize.width, 1280)
        XCTAssertLessThanOrEqual(plan.coverSize.height, 720)
        XCTAssertEqual(plan.videoSize.width, plan.coverSize.width - plan.coverSize.width % 2)
    }

    func testPortraitTargetFromLandscapeSource() {
        let plan = Reframe.plan(sourceSize: CGSize(width: 1920, height: 1080), aspect: 1179.0 / 2556.0, mode: .crop)
        XCTAssertEqual(plan.coverSize.height, 1080)
        XCTAssertEqual(Double(plan.coverSize.width) / Double(plan.coverSize.height), 1179.0 / 2556.0, accuracy: 0.002)
    }

    func testVideoZoomCropsWholePixelsEvenly() {
        let full = CGRect(x: 0, y: 0, width: 2856, height: 2008)
        XCTAssertEqual(WallpaperBuilder.zoomed(full, by: 1), full)
        // 0.17%: 2.4 px and 1.7 px per side round to 2 and 2, centre unchanged
        let z = WallpaperBuilder.zoomed(full, by: 1.0017)
        XCTAssertEqual(z, CGRect(x: 2, y: 2, width: 2852, height: 2004))
        XCTAssertEqual(z.midX, full.midX)
        XCTAssertEqual(z.midY, full.midY)
    }
}
