/// SnapDividerGeometryTests.swift

import XCTest
import CoreGraphics
@testable import Rectangle

final class SnapDividerGeometryTests: XCTestCase {
    /// Two halves of a 1440 x 875 visible area below a 25 pt menu bar.
    private let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
    private let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 875)

    private func seam(_ left: CGRect, _ right: CGRect, maxGap: CGFloat = 8, maxOverlap: CGFloat = 8,
                      minimumSpan: CGFloat = 100) -> SnapDividerGeometry.Seam? {
        SnapDividerGeometry.seam(left: left, right: right, maxGap: maxGap, maxOverlap: maxOverlap,
                                 minimumSpan: minimumSpan)
    }

    func testTouchingHalvesFormASeamOnTheSharedEdge() {
        let seam = seam(leftHalf, rightHalf)

        XCTAssertEqual(seam?.position, 720)
        XCTAssertEqual(seam?.gap, 0)
        XCTAssertEqual(seam?.span, 25...900)
    }

    func testSeamIsCentredInTheGap() {
        let left = CGRect(x: 10, y: 35, width: 705, height: 855)
        let right = CGRect(x: 725, y: 35, width: 705, height: 855)

        let seam = seam(left, right, maxGap: 18)

        XCTAssertEqual(seam?.position, 720)
        XCTAssertEqual(seam?.gap, 10)
    }

    func testGapWiderThanAllowedIsNotASeam() {
        let right = rightHalf.offsetBy(dx: 9, dy: 0)

        XCTAssertNil(seam(leftHalf, right))
        XCTAssertNotNil(seam(leftHalf, rightHalf.offsetBy(dx: 8, dy: 0)))
    }

    func testSlightOverlapIsASeamInTheMiddleOfTheOverlap() {
        // The left window refused to shrink below its minimum width.
        let left = CGRect(x: 0, y: 25, width: 726, height: 875)

        let seam = seam(left, rightHalf)

        XCTAssertEqual(seam?.position, 723)
        XCTAssertEqual(seam?.gap, 0)
    }

    func testOverlapDeeperThanAllowedIsNotASeam() {
        let left = CGRect(x: 0, y: 25, width: 729, height: 875)

        XCTAssertNil(seam(left, rightHalf))
    }

    func testWindowsInTheWrongOrderAreNotASeam() {
        XCTAssertNil(seam(rightHalf, leftHalf))
    }

    func testIdenticalFramesAreNotASeam() {
        XCTAssertNil(seam(leftHalf, leftHalf))
    }

    func testSpanIsThePartOfTheEdgeBothWindowsCover() {
        let topRightQuarter = CGRect(x: 720, y: 25, width: 720, height: 437)

        XCTAssertEqual(seam(leftHalf, topRightQuarter)?.span, 25...462)
    }

    func testWindowsMeetingOnlyNearACornerAreNotASeam() {
        let right = rightHalf.offsetBy(dx: 0, dy: 800)

        XCTAssertNil(seam(leftHalf, right))
        XCTAssertNotNil(seam(leftHalf, right, minimumSpan: 75))
    }

    func testStackedWindowsAreNotASeam() {
        let top = CGRect(x: 0, y: 25, width: 1440, height: 437)
        let bottom = CGRect(x: 0, y: 462, width: 1440, height: 438)

        XCTAssertNil(seam(top, bottom))
        XCTAssertNil(seam(bottom, top))
    }

    func testUnusableFramesAreNotASeam() {
        XCTAssertNil(seam(.null, rightHalf))
        XCTAssertNil(seam(leftHalf, .zero))
        XCTAssertNil(seam(leftHalf, CGRect(x: 720, y: CGFloat.nan, width: 720, height: 875)))
    }

    func testPointIsNearTheSeamWithinTheGapAndTheSlop() {
        let seam = SnapDividerGeometry.Seam(position: 720, gap: 10, span: 25...900)

        XCTAssertTrue(seam.isNear(CGPoint(x: 720, y: 400), slop: 4))
        XCTAssertTrue(seam.isNear(CGPoint(x: 711, y: 400), slop: 4))
        XCTAssertTrue(seam.isNear(CGPoint(x: 729, y: 400), slop: 4))
        XCTAssertFalse(seam.isNear(CGPoint(x: 710, y: 400), slop: 4))
        XCTAssertFalse(seam.isNear(CGPoint(x: 730, y: 400), slop: 4))
    }

    func testPointBeyondTheSharedSpanIsNotNearTheSeam() {
        let seam = SnapDividerGeometry.Seam(position: 720, gap: 0, span: 25...462)

        XCTAssertTrue(seam.isNear(CGPoint(x: 720, y: 462), slop: 4))
        XCTAssertFalse(seam.isNear(CGPoint(x: 720, y: 463), slop: 4))
        XCTAssertFalse(seam.isNear(CGPoint(x: 720, y: 24), slop: 4))
    }
}

final class SnapDividerMatchTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
    private let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 875)

    private func window(_ id: CGWindowID, _ frame: CGRect, level: CGWindowLevel = kCGNormalWindowLevel,
                        alpha: CGFloat = 1) -> WindowInfo {
        WindowInfo(id: id, level: level, frame: frame, pid: pid_t(id), processName: "App \(id)", alpha: alpha)
    }

    /// `windows` is front to back, as the window list returns them.
    private func match(_ windows: [WindowInfo], at point: CGPoint = CGPoint(x: 720, y: 400),
                       in screenFrame: CGRect? = nil, gap: CGFloat = 0,
                       ignoring: Set<CGWindowID> = []) -> SnapDividerManager.Match? {
        SnapDividerManager.match(at: point, in: screenFrame ?? screen, windows: windows,
                                 configuredGap: gap, ignoring: ignoring)
    }

    func testCursorOnTheSeamMatchesBothWindowsWhateverTheirOrder() {
        for windows in [[window(1, leftHalf), window(2, rightHalf)],
                        [window(2, rightHalf), window(1, leftHalf)]] {
            let match = match(windows)

            XCTAssertEqual(match?.left.id, 1)
            XCTAssertEqual(match?.right.id, 2)
            XCTAssertEqual(match?.seam.position, 720)
        }
    }

    func testCursorJustInsideEitherWindowStillMatches() {
        let windows = [window(1, leftHalf), window(2, rightHalf)]

        XCTAssertNotNil(match(windows, at: CGPoint(x: 716, y: 400)))
        XCTAssertNotNil(match(windows, at: CGPoint(x: 724, y: 400)))
        XCTAssertNil(match(windows, at: CGPoint(x: 715, y: 400)))
        XCTAssertNil(match(windows, at: CGPoint(x: 725, y: 400)))
    }

    func testCursorInAConfiguredGapMatchesAcrossIt() {
        let left = CGRect(x: 20, y: 45, width: 690, height: 835)
        let right = CGRect(x: 730, y: 45, width: 690, height: 835)
        let windows = [window(1, left), window(2, right)]

        XCTAssertEqual(match(windows, gap: 20)?.seam.gap, 20)
        XCTAssertNotNil(match(windows, at: CGPoint(x: 711, y: 400), gap: 20))
        XCTAssertNotNil(match(windows, at: CGPoint(x: 729, y: 400), gap: 20))
        XCTAssertNil(match(windows, gap: 0), "A gap far wider than the configured one is not a seam")
    }

    func testWindowBehindShowingThroughTheGapDoesNotBlockTheMatch() {
        let left = CGRect(x: 20, y: 45, width: 690, height: 835)
        let right = CGRect(x: 730, y: 45, width: 690, height: 835)
        let behind = window(3, CGRect(x: 100, y: 100, width: 1200, height: 600))

        XCTAssertNotNil(match([window(1, left), window(2, right), behind], gap: 20))
    }

    func testWindowCoveringTheSeamBlocksTheMatch() {
        let cover = window(3, CGRect(x: 400, y: 200, width: 600, height: 400))
        let windows = [cover, window(1, leftHalf), window(2, rightHalf)]

        XCTAssertNil(match(windows))
        XCTAssertNotNil(match(windows, at: CGPoint(x: 720, y: 700)), "The seam is free below the covering window")
    }

    func testNarrowWindowCoveringTheSeamBetweenTheProbesBlocksTheMatch() {
        let sliver = window(3, CGRect(x: 714, y: 200, width: 12, height: 400))

        XCTAssertNil(match([sliver, window(1, leftHalf), window(2, rightHalf)]))
    }

    func testIgnoredWindowOverTheSeamDoesNotBlockTheMatch() {
        let handle = window(9, CGRect(x: 716, y: 25, width: 8, height: 875), level: 3)
        let windows = [handle, window(1, leftHalf), window(2, rightHalf)]

        XCTAssertNil(match(windows))
        XCTAssertNotNil(match(windows, ignoring: [9]))
    }

    func testInvisibleWindowOverTheSeamDoesNotBlockTheMatch() {
        let invisible = window(3, screen, alpha: 0)

        XCTAssertNotNil(match([invisible, window(1, leftHalf), window(2, rightHalf)]))
    }

    func testFloatingWindowIsNotOneSideOfASeam() {
        let palette = window(1, leftHalf, level: 3)

        XCTAssertNil(match([palette, window(2, rightHalf)]))
    }

    func testSingleWindowDoesNotMatch() {
        XCTAssertNil(match([window(1, leftHalf)]))
        XCTAssertNil(match([window(1, CGRect(x: 0, y: 25, width: 1440, height: 875))]))
    }

    func testWindowsMeetingAtADisplayBoundaryDoNotMatch() {
        let secondScreen = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let windows = [window(1, CGRect(x: 720, y: 25, width: 720, height: 875)),
                       window(2, CGRect(x: 1440, y: 25, width: 720, height: 875))]
        let boundary = CGPoint(x: 1440, y: 400)

        XCTAssertNil(match(windows, at: boundary, in: screen))
        XCTAssertNil(match(windows, at: boundary, in: secondScreen))
    }

    func testSeamOnASecondDisplayMatches() {
        let secondScreen = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let windows = [window(1, CGRect(x: 1440, y: -175, width: 960, height: 1055)),
                       window(2, CGRect(x: 2400, y: -175, width: 960, height: 1055))]

        XCTAssertEqual(match(windows, at: CGPoint(x: 2400, y: 300), in: secondScreen)?.seam.position, 2400)
    }
}
