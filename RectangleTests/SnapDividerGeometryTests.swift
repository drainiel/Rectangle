/// SnapDividerGeometryTests.swift

import XCTest
import CoreGraphics
@testable import Rectangle

// Most of these tests are about one window either side of a seam, so they
// speak of a left and a right window. The types themselves take any number.
private extension SnapDividerGeometry.Frames {
    init(left: CGRect, right: CGRect) {
        self.init(leading: [left], trailing: [right])
    }

    var left: CGRect { leading[0] }
    var right: CGRect { trailing[0] }
}

private extension SnapDividerGeometry {
    static func resized(_ frames: Frames, gap: CGFloat, minimumLeftWidth: CGFloat, minimumRightWidth: CGFloat,
                        seamAt position: CGFloat) -> Frames {
        resized(frames, gap: gap, minimumLeadingWidths: [minimumLeftWidth],
                minimumTrailingWidths: [minimumRightWidth], seamAt: position)
    }
}

private extension SnapDividerResize {
    static func apply(_ target: SnapDividerGeometry.Frames, gap: CGFloat,
                      left: SnapDividerWindow, right: SnapDividerWindow,
                      from known: SnapDividerGeometry.Frames? = nil, cautious: Bool = false) -> Outcome {
        apply(target, gap: gap, leading: [left], trailing: [right], from: known, cautious: cautious)
    }
}

private extension SnapDividerManager.Match {
    var left: WindowInfo { leading[0] }
    var right: WindowInfo { trailing[0] }
}

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

    func testClearStretchIsTheWholeSpanWhenNothingCoversIt() {
        XCTAssertEqual(SnapDividerGeometry.clearStretch(of: 25...900, around: 400, blockedBy: []), 25...900)
    }

    func testClearStretchStopsAtTheNearestCoverOnEachSide() {
        let blocked: [ClosedRange<CGFloat>] = [50...100, 120...200, 600...700, 650...800]

        XCTAssertEqual(SnapDividerGeometry.clearStretch(of: 25...900, around: 400, blockedBy: blocked), 200...600)
        XCTAssertEqual(SnapDividerGeometry.clearStretch(of: 25...900, around: 850, blockedBy: blocked), 800...900)
        XCTAssertEqual(SnapDividerGeometry.clearStretch(of: 25...900, around: 30, blockedBy: blocked), 25...50)
    }

    func testClearStretchIgnoresCoverBeyondTheSpan() {
        XCTAssertEqual(SnapDividerGeometry.clearStretch(of: 25...900, around: 400, blockedBy: [-200...10, 950...1200]),
                       25...900)
    }

    func testNoClearStretchWhereTheSeamIsCoveredOrOutsideTheSpan() {
        XCTAssertNil(SnapDividerGeometry.clearStretch(of: 25...900, around: 400, blockedBy: [300...500]))
        XCTAssertNil(SnapDividerGeometry.clearStretch(of: 25...900, around: 950, blockedBy: []))
    }

    private func handleFrame(position: CGFloat = 720, gap: CGFloat = 0, within stretch: ClosedRange<CGFloat>,
                             minimumLength: CGFloat = 48) -> CGRect {
        SnapDividerGeometry.handleFrame(on: SnapDividerGeometry.Seam(position: position, gap: gap, span: 25...925),
                                        within: stretch, thickness: 6, lengthFraction: 1.0 / 3.0,
                                        minimumLength: minimumLength)
    }

    func testHandleCoversAThirdOfTheStretchCentredOnTheSeam() {
        XCTAssertEqual(handleFrame(within: 25...925), CGRect(x: 717, y: 325, width: 6, height: 300))
    }

    func testHandleIsCentredInAGap() {
        // Facing edges at 710 and 730: the handle leaves 7 pt on either side.
        XCTAssertEqual(handleFrame(position: 720, gap: 20, within: 25...925).minX, 717)
        XCTAssertEqual(handleFrame(position: 720, gap: 20, within: 25...925).maxX, 723)
    }

    func testHandleIsCentredOnTheClearStretchRatherThanTheWholeSeam() {
        XCTAssertEqual(handleFrame(within: 625...925), CGRect(x: 717, y: 725, width: 6, height: 100))
    }

    func testHandleKeepsAMinimumLengthButNeverOutgrowsTheStretch() {
        XCTAssertEqual(handleFrame(within: 100...200).height, 48)
        XCTAssertEqual(handleFrame(within: 100...200).midY, 150)
        XCTAssertEqual(handleFrame(within: 100...130), CGRect(x: 717, y: 100, width: 6, height: 30))
    }

    func testHandleLandsOnWholePoints() {
        let frame = handleFrame(position: 723.5, within: 25...462)

        XCTAssertEqual(frame, frame.integral)
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
        XCTAssertEqual(match(windows, at: CGPoint(x: 720, y: 700))?.clearSpan, 600...900,
                       "The seam is free below the covering window")
        XCTAssertEqual(match(windows, at: CGPoint(x: 720, y: 150))?.clearSpan, 25...200,
                       "The seam is free above the covering window")
    }

    func testTooShortAFreeStretchDoesNotMatch() {
        let cover = window(3, CGRect(x: 400, y: 110, width: 600, height: 700))
        let windows = [cover, window(1, leftHalf), window(2, rightHalf)]

        XCTAssertNil(match(windows, at: CGPoint(x: 720, y: 60)))
        XCTAssertNil(match(windows, at: CGPoint(x: 720, y: 850)))
    }

    func testClearSpanIsTheWholeSeamWhenNothingCoversIt() {
        XCTAssertEqual(match([window(1, leftHalf), window(2, rightHalf)])?.clearSpan, 25...900)
    }

    func testWindowBesideTheSeamDoesNotShortenTheClearSpan() {
        let beside = window(3, CGRect(x: 100, y: 200, width: 600, height: 400))
        let justTouching = window(4, CGRect(x: 100, y: 650, width: 613, height: 100))
        let windows = [beside, justTouching, window(1, leftHalf), window(2, rightHalf)]

        XCTAssertEqual(match(windows)?.clearSpan, 25...650)
    }

    func testMatchLookedUpAgainAtTheHandleIsTheSame() {
        let cover = window(3, CGRect(x: 400, y: 200, width: 600, height: 400))
        let windows = [cover, window(1, leftHalf), window(2, rightHalf)]
        let first = match(windows, at: CGPoint(x: 723, y: 880))
        let again = match(windows, at: CGPoint(x: 720, y: 750))

        XCTAssertNotNil(first)
        XCTAssertEqual(again.map { first?.isSame(as: $0) }, true)
        XCTAssertEqual(match(windows.dropFirst().map { $0 }, at: CGPoint(x: 720, y: 750)).map { first?.isSame(as: $0) },
                       false, "Uncovering the seam changes the match")
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

final class SnapDividerResizeGeometryTests: XCTestCase {
    private typealias Frames = SnapDividerGeometry.Frames
    private let halves = SnapDividerGeometry.Frames(left: CGRect(x: 0, y: 25, width: 720, height: 875),
                                                   right: CGRect(x: 720, y: 25, width: 720, height: 875))

    private func resized(_ frames: Frames? = nil, gap: CGFloat = 0, minimumLeft: CGFloat = 150,
                         minimumRight: CGFloat = 150, seamAt position: CGFloat) -> Frames {
        SnapDividerGeometry.resized(frames ?? halves, gap: gap, minimumLeftWidth: minimumLeft,
                                    minimumRightWidth: minimumRight, seamAt: position)
    }

    func testIntendedGapPutsANearMissBackOnTheConfiguredGap() {
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: 0, configuredGap: 0, tolerance: 8), 0)
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: 5, configuredGap: 0, tolerance: 8), 0,
                       "A terminal that stopped a cell short")
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: -6, configuredGap: 0, tolerance: 8), 0,
                       "A window reaching past its edge")
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: 23, configuredGap: 20, tolerance: 8), 20)
    }

    func testIntendedGapKeepsADistanceThatWasArrangedThatWay() {
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: 0, configuredGap: 20, tolerance: 8), 0,
                       "Touching windows stay touching although a gap is configured")
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: 15, configuredGap: 0, tolerance: 8), 15)
        XCTAssertEqual(SnapDividerGeometry.intendedGap(distance: -15, configuredGap: 0, tolerance: 8), 0)
    }

    func testMovingTheSeamGrowsOneWindowAndShrinksTheOther() {
        let moved = resized(seamAt: 600)

        XCTAssertEqual(moved.left, CGRect(x: 0, y: 25, width: 600, height: 875))
        XCTAssertEqual(moved.right, CGRect(x: 600, y: 25, width: 840, height: 875))
        XCTAssertEqual(moved.seamPosition, 600)
    }

    func testMovedSeamKeepsTheGapCentredOnIt() {
        let gapped = Frames(left: CGRect(x: 20, y: 45, width: 690, height: 835),
                            right: CGRect(x: 730, y: 45, width: 690, height: 835))

        let moved = resized(gapped, gap: 20, seamAt: 900)

        XCTAssertEqual(moved.left.maxX, 890)
        XCTAssertEqual(moved.right.minX, 910)
        XCTAssertEqual(moved.left.minX, 20, "The far edges stay where they were")
        XCTAssertEqual(moved.right.maxX, 1420)
    }

    func testSeamStopsAtEachWindowsMinimumWidth() {
        XCTAssertEqual(resized(minimumLeft: 400, seamAt: 100).left.width, 400)
        XCTAssertEqual(resized(minimumRight: 500, seamAt: 1400).right.width, 500)
        XCTAssertEqual(resized(minimumRight: 500, seamAt: 1400).left.width, 940)
    }

    func testMinimumWidthsAllowForTheGap() {
        let gapped = Frames(left: CGRect(x: 0, y: 25, width: 710, height: 875),
                            right: CGRect(x: 730, y: 25, width: 710, height: 875))

        let moved = resized(gapped, gap: 20, minimumRight: 500, seamAt: 1400)

        XCTAssertEqual(moved.right, CGRect(x: 940, y: 25, width: 500, height: 875))
        XCTAssertEqual(moved.left.maxX, 920)
    }

    func testFacingEdgesLandOnWholePoints() {
        XCTAssertEqual(resized(seamAt: 600.4).left.maxX, 600)
        XCTAssertEqual(resized(seamAt: 600.6).right.minX, 601)
        XCTAssertEqual(resized(gap: 5, seamAt: 600).left.maxX, 598)
        XCTAssertEqual(resized(gap: 5, seamAt: 600).right.minX, 603)
    }

    func testNothingMovesWhenTheMinimumWidthsCannotBothFit() {
        XCTAssertEqual(resized(minimumLeft: 800, minimumRight: 800, seamAt: 600), halves)
        XCTAssertEqual(resized(seamAt: .nan), halves)
    }

    func testMovingTheSeamLeavesVerticalGeometryAlone() {
        let uneven = Frames(left: CGRect(x: 0, y: 25, width: 720, height: 875),
                            right: CGRect(x: 720, y: 25, width: 720, height: 437))

        let moved = resized(uneven, seamAt: 500)

        XCTAssertEqual(moved.left, CGRect(x: 0, y: 25, width: 500, height: 875))
        XCTAssertEqual(moved.right, CGRect(x: 500, y: 25, width: 940, height: 437))
    }
}

/// A window that takes any position, and the width its app allows.
private final class FakeDividerWindow: SnapDividerWindow {
    final class Calls {
        var made = [String]()
    }

    let name: String
    private var current: CGRect
    private let allowedWidth: (CGFloat) -> CGFloat
    private let calls: Calls
    private(set) var widthsAsked = [CGFloat]()
    /// The widest overlap with `neighbour` seen straight after any write.
    var neighbour: FakeDividerWindow?
    private(set) var worstOverlap: CGFloat = 0
    /// How far short of `farEdge` the window's right edge has been seen
    /// straight after any write.
    var farEdge: CGFloat?
    private(set) var worstShortfall: CGFloat = 0
    /// Where the screen ends, if the window may not be resized past it.
    var screenEdge: CGFloat?
    var readable = true

    init(_ name: String, _ frame: CGRect, calls: Calls, allowedWidth: @escaping (CGFloat) -> CGFloat = { $0 }) {
        self.name = name
        current = frame
        self.calls = calls
        self.allowedWidth = allowedWidth
    }

    var frame: CGRect? { readable ? current : nil }

    func setPosition(_ position: CGPoint) {
        calls.made.append("\(name) position")
        current.origin = position
        note()
    }

    func setSize(_ size: CGSize) {
        calls.made.append("\(name) size")
        widthsAsked.append(size.width)
        var width = allowedWidth(size.width)
        if let screenEdge { width = min(width, screenEdge - current.minX) }
        current.size = CGSize(width: width, height: size.height)
        note()
    }

    private func note() {
        if let farEdge { worstShortfall = max(worstShortfall, farEdge - current.maxX) }
        guard let other = neighbour?.current else { return }
        let overlap = current.intersection(other)
        if !overlap.isNull { worstOverlap = max(worstOverlap, overlap.width) }
    }
}

final class SnapDividerResizeTests: XCTestCase {
    private typealias Frames = SnapDividerGeometry.Frames

    private let calls = FakeDividerWindow.Calls()
    private let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
    private let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 875)

    private func target(seamAt position: CGFloat, gap: CGFloat = 0) -> Frames {
        SnapDividerGeometry.resized(Frames(left: leftHalf, right: rightHalf), gap: gap,
                                    minimumLeftWidth: 150, minimumRightWidth: 150, seamAt: position)
    }

    private func windows(left leftWidth: @escaping (CGFloat) -> CGFloat = { $0 },
                         right rightWidth: @escaping (CGFloat) -> CGFloat = { $0 }) -> (left: FakeDividerWindow, right: FakeDividerWindow) {
        let left = FakeDividerWindow("left", leftHalf, calls: calls, allowedWidth: leftWidth)
        let right = FakeDividerWindow("right", rightHalf, calls: calls, allowedWidth: rightWidth)
        left.neighbour = right
        right.neighbour = left
        right.farEdge = rightHalf.maxX
        return (left, right)
    }

    /// A terminal: only as wide as a whole number of 7 pt cells.
    private func cells(_ width: CGFloat) -> CGFloat { (width / 7).rounded(.down) * 7 }

    func testTheGrowingWindowGoesFirstSoNoDesktopShowsBetweenTheTwo() {
        let (left, right) = windows()

        let outcome = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final, target(seamAt: 600))
        XCTAssertFalse(outcome.wasRevised)
        XCTAssertEqual(calls.made, ["right size", "right position", "left size"])
    }

    func testMovingTheSeamRightGrowsTheLeftWindowFirst() {
        let (left, right) = windows()

        let outcome = SnapDividerResize.apply(target(seamAt: 900), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final, target(seamAt: 900))
        XCTAssertEqual(calls.made, ["left size", "right position", "right size"])
    }

    func testRightWindowNeverFallsShortOfItsRightEdgeOnTheWay() {
        for position in [CGFloat(600), 900] {
            for cautious in [false, true] {
                let (left, right) = windows()

                _ = SnapDividerResize.apply(target(seamAt: position), gap: 0, left: left, right: right,
                                            cautious: cautious)

                XCTAssertEqual(right.worstShortfall, 0, "seam to \(position), cautious \(cautious)")
            }
        }
    }

    func testCautiousOrderAsksTheWindowThatGivesWayFirst() {
        var (left, right) = windows()
        _ = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right, cautious: true)
        XCTAssertEqual(calls.made, ["left size", "right size", "right position"])

        calls.made = []
        (left, right) = windows()
        let outcome = SnapDividerResize.apply(target(seamAt: 900), gap: 0, left: left, right: right, cautious: true)
        XCTAssertEqual(calls.made, ["right position", "right size", "left size"])
        XCTAssertEqual(outcome.final, target(seamAt: 900))
    }

    func testWindowHeldBackAtTheScreenEdgeGrowsOnceItHasBeenMoved() {
        let (left, right) = windows()
        right.screenEdge = 1440

        let outcome = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final, target(seamAt: 600))
    }

    func testNothingIsWrittenWhenTheWindowsAreAlreadyThere() {
        let (left, right) = windows()

        let outcome = SnapDividerResize.apply(target(seamAt: 720), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final, Frames(left: leftHalf, right: rightHalf))
        XCTAssertEqual(calls.made, [])
    }

    func testWindowDraggedPastItsUnreportedMinimumEndsWhereItAllows() {
        let (left, right) = windows(left: { max($0, 500) })

        let outcome = SnapDividerResize.apply(target(seamAt: 300), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 500, height: 875))
        XCTAssertEqual(outcome.final?.right, CGRect(x: 500, y: 25, width: 940, height: 875))
        XCTAssertTrue(outcome.wasRevised)
    }

    func testCautiouslyAWindowDraggedPastItsMinimumIsNeverOverlapped() {
        let (left, right) = windows(left: { max($0, 500) })

        let outcome = SnapDividerResize.apply(target(seamAt: 300), gap: 0, left: left, right: right, cautious: true)

        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 500, height: 875))
        XCTAssertEqual(outcome.final?.right, CGRect(x: 500, y: 25, width: 940, height: 875))
        XCTAssertTrue(outcome.wasRevised)
        XCTAssertEqual(right.widthsAsked, [940], "The right window is only ever given what the left one gave up")
        XCTAssertEqual(max(left.worstOverlap, right.worstOverlap), 0)
    }

    func testRightWindowDraggedPastItsUnreportedMinimumKeepsItsRightEdge() {
        let (left, right) = windows(right: { max($0, 600) })

        let outcome = SnapDividerResize.apply(target(seamAt: 1200), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final?.right, CGRect(x: 840, y: 25, width: 600, height: 875))
        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 840, height: 875))
    }

    func testCautiouslyARightWindowDraggedPastItsMinimumIsNeverOverlapped() {
        let (left, right) = windows(right: { max($0, 600) })

        let outcome = SnapDividerResize.apply(target(seamAt: 1200), gap: 0, left: left, right: right, cautious: true)

        XCTAssertEqual(outcome.final?.right, CGRect(x: 840, y: 25, width: 600, height: 875))
        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 840, height: 875))
        XCTAssertEqual(left.widthsAsked, [840])
        XCTAssertEqual(max(left.worstOverlap, right.worstOverlap), 0)
    }

    func testTerminalOnTheRightEndsFlushWithItsFarEdgeAndTheLeftWindowMeetsIt() {
        let (left, right) = windows(right: cells)

        let outcome = SnapDividerResize.apply(target(seamAt: 603), gap: 0, left: left, right: right)

        // 837 pt was offered to the terminal, and 833 is the most whole cells.
        XCTAssertEqual(outcome.final?.right, CGRect(x: 607, y: 25, width: 833, height: 875))
        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 607, height: 875))
    }

    func testTerminalOnTheLeftIsMetByTheRightWindow() {
        let (left, right) = windows(left: cells)

        let outcome = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 595, height: 875))
        XCTAssertEqual(outcome.final?.right, CGRect(x: 595, y: 25, width: 845, height: 875))
    }

    func testTerminalThatShrinksOnTheRightIsMetByTheLeftWindow() {
        let (left, right) = windows(right: cells)

        let outcome = SnapDividerResize.apply(target(seamAt: 905), gap: 0, left: left, right: right)

        // 535 pt was asked of the terminal, and 532 is the most whole cells.
        XCTAssertEqual(outcome.final?.right, CGRect(x: 908, y: 25, width: 532, height: 875))
        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 25, width: 908, height: 875))
    }

    func testTwoTerminalsMeetAtTheSeamAndLeaveTheirSlackAtTheFarEdge() {
        let (left, right) = windows(left: cells, right: cells)

        let outcome = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        guard let final = outcome.final else { return XCTFail("The windows should be readable") }
        XCTAssertEqual(final.left.maxX, final.right.minX, "No gap and no overlap between the two")
        XCTAssertEqual(final.left.minX, 0)
        XCTAssertLessThanOrEqual(final.right.maxX, 1440)
        XCTAssertGreaterThan(final.right.maxX, 1433, "The slack is less than one cell")
    }

    func testRefusalIsSettledAroundAGap() {
        let gappedLeft = CGRect(x: 20, y: 45, width: 690, height: 835)
        let gappedRight = CGRect(x: 730, y: 45, width: 690, height: 835)
        let left = FakeDividerWindow("left", gappedLeft, calls: calls) { max($0, 600) }
        let right = FakeDividerWindow("right", gappedRight, calls: calls)
        let target = SnapDividerGeometry.resized(Frames(left: gappedLeft, right: gappedRight), gap: 20,
                                                 minimumLeftWidth: 150, minimumRightWidth: 150, seamAt: 400)

        let outcome = SnapDividerResize.apply(target, gap: 20, left: left, right: right)

        XCTAssertEqual(outcome.final?.left.maxX, 620)
        XCTAssertEqual(outcome.final?.right.minX, 640)
        XCTAssertEqual(outcome.final?.right.maxX, 1420)
    }

    func testVerticalGeometryIsLeftAsTheWindowsHaveIt() {
        // The target says one thing about height and the windows another.
        let left = FakeDividerWindow("left", CGRect(x: 0, y: 30, width: 720, height: 800), calls: calls)
        let right = FakeDividerWindow("right", CGRect(x: 720, y: 40, width: 720, height: 700), calls: calls)

        let outcome = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        XCTAssertEqual(outcome.final?.left, CGRect(x: 0, y: 30, width: 600, height: 800))
        XCTAssertEqual(outcome.final?.right, CGRect(x: 600, y: 40, width: 840, height: 700))
    }

    func testKnownFramesSaveReadingTheWindowsFirst() {
        let (left, right) = windows()
        let first = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        let second = SnapDividerResize.apply(target(seamAt: 650), gap: 0, left: left, right: right, from: first.final)

        XCTAssertEqual(second.final, target(seamAt: 650))
    }

    func testNothingIsWrittenToWindowsThatCannotBeRead() {
        let (left, right) = windows()
        right.readable = false

        let outcome = SnapDividerResize.apply(target(seamAt: 600), gap: 0, left: left, right: right)

        XCTAssertNil(outcome.final)
        XCTAssertEqual(calls.made, [])
    }
}

final class SnapDividerResizeSessionTests: XCTestCase {
    private typealias Frames = SnapDividerGeometry.Frames

    private let calls = FakeDividerWindow.Calls()
    private lazy var left = FakeDividerWindow("left", CGRect(x: 0, y: 25, width: 720, height: 875), calls: calls)
    private lazy var right = FakeDividerWindow("right", CGRect(x: 720, y: 25, width: 720, height: 875), calls: calls)

    /// Blocks handed to the session's two queues, run by hand so the test
    /// decides when a resize finishes.
    private var work = [() -> Void]()
    private var replies = [() -> Void]()
    private var events = [String]()

    private func session() -> SnapDividerResizeSession {
        SnapDividerResizeSession(leading: [left], trailing: [right], gap: 0,
                                 work: { self.work.append($0) },
                                 reply: { self.replies.append($0) },
                                 begin: {
                                     self.events.append("begin")
                                     return { self.events.append("end") }
                                 })
    }

    private func target(seamAt position: CGFloat) -> Frames {
        SnapDividerGeometry.resized(Frames(left: CGRect(x: 0, y: 25, width: 720, height: 875),
                                           right: CGRect(x: 720, y: 25, width: 720, height: 875)),
                                    gap: 0, minimumLeftWidth: 150, minimumRightWidth: 150, seamAt: position)
    }

    /// Lets the resize in progress run to its end and report back.
    private func finishOneStep() {
        XCTAssertEqual(work.count, 1, "Only one resize is ever in progress")
        work.removeFirst()()
        XCTAssertEqual(replies.count, 1)
        replies.removeFirst()()
    }

    func testOnlyTheLatestOfTheRequestsMadeDuringAResizeIsApplied() {
        let session = session()

        session.request(target(seamAt: 700))
        session.request(target(seamAt: 650))
        session.request(target(seamAt: 600))
        session.request(target(seamAt: 500))
        XCTAssertEqual(work.count, 1, "The first request started; the rest wait")

        finishOneStep()
        XCTAssertEqual(left.widthsAsked, [700])
        XCTAssertEqual(work.count, 1, "One follow-up, not three")

        finishOneStep()
        XCTAssertEqual(left.widthsAsked, [700, 500], "The positions in between were never applied")
        XCTAssertEqual(work.count, 0, "Nothing is left over")
    }

    func testAfterAWindowRefusesASizeTheNextResizeIsCautious() {
        left = FakeDividerWindow("left", CGRect(x: 0, y: 25, width: 720, height: 875), calls: calls) { max($0, 650) }
        let session = session()

        session.request(target(seamAt: 700))
        finishOneStep()
        XCTAssertEqual(calls.made, ["right size", "right position", "left size"], "All went as asked: the growing window first")

        calls.made = []
        session.request(target(seamAt: 600))
        finishOneStep()
        XCTAssertEqual(calls.made.first, "right size", "Still the growing window first; the refusal was not known yet")

        calls.made = []
        session.request(target(seamAt: 550))
        finishOneStep()
        XCTAssertEqual(calls.made, ["left size"],
                       "The window that refused is asked first, refuses again, and the other is left alone")
    }

    func testFinishWaitsForTheLastRequestAndReportsWhereTheWindowsEndedUp() {
        let session = session()
        var outcomes = [SnapDividerResize.Outcome?]()

        session.request(target(seamAt: 700))
        session.request(target(seamAt: 500))
        session.finish { outcomes.append($0) }
        XCTAssertTrue(outcomes.isEmpty)

        finishOneStep()
        XCTAssertTrue(outcomes.isEmpty, "The last position has not been applied yet")
        finishOneStep()
        XCTAssertTrue(outcomes.isEmpty)
        finishOneStep()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first??.final, target(seamAt: 500))
        XCTAssertEqual(events, ["begin", "end"], "Begun once before the first resize and ended once after the last")
        XCTAssertEqual(work.count, 0)
    }

    func testRequestsAfterFinishAreIgnored() {
        let session = session()
        var finished = 0

        session.request(target(seamAt: 700))
        session.finish { _ in finished += 1 }
        session.request(target(seamAt: 400))
        finishOneStep()
        finishOneStep()

        XCTAssertEqual(finished, 1)
        XCTAssertEqual(left.widthsAsked, [700])
        XCTAssertEqual(work.count, 0)
    }

    func testCancelDropsWhatHasNotStartedButStillEnds() {
        let session = session()

        session.request(target(seamAt: 700))
        session.request(target(seamAt: 400))
        session.cancel()
        finishOneStep()
        finishOneStep()

        XCTAssertEqual(left.widthsAsked, [700], "The resize under way finished; the one waiting was dropped")
        XCTAssertEqual(events, ["begin", "end"])
        XCTAssertEqual(work.count, 0)
    }

    func testSessionThatWasNeverAskedForAnythingTouchesNothing() {
        let session = session()
        var outcomes = [SnapDividerResize.Outcome?]()

        session.finish { outcomes.append($0) }
        finishOneStep()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes[0])
        XCTAssertEqual(events, [])
        XCTAssertEqual(calls.made, [])
    }
}

final class SnapDividerArrangementTests: XCTestCase {
    private typealias Frames = SnapDividerGeometry.Frames
    private let stacked = SnapDividerGeometry.Arrangement.stacked
    private let sideBySide = SnapDividerGeometry.Arrangement.sideBySide

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let topHalf = CGRect(x: 0, y: 25, width: 1440, height: 437)
    private let bottomHalf = CGRect(x: 0, y: 462, width: 1440, height: 438)

    private func window(_ id: CGWindowID, _ frame: CGRect) -> WindowInfo {
        WindowInfo(id: id, level: kCGNormalWindowLevel, frame: frame, pid: pid_t(id), processName: "App \(id)", alpha: 1)
    }

    private func match(_ windows: [WindowInfo], at point: CGPoint, _ arrangement: SnapDividerGeometry.Arrangement,
                       in screenFrame: CGRect? = nil, gap: CGFloat = 0) -> SnapDividerManager.Match? {
        SnapDividerManager.match(at: point, in: screenFrame ?? screen, windows: windows,
                                 configuredGap: gap, arrangement: arrangement)
    }

    func testStackedGeometryChangesXAndYRoundAndBackAgain() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)

        XCTAssertEqual(stacked.canonical(rect), CGRect(x: 20, y: 10, width: 400, height: 300))
        XCTAssertEqual(stacked.canonical(stacked.canonical(rect)), rect)
        XCTAssertEqual(stacked.canonical(CGPoint(x: 1, y: 2)), CGPoint(x: 2, y: 1))
        XCTAssertEqual(stacked.canonical(CGSize(width: 1, height: 2)), CGSize(width: 2, height: 1))
        XCTAssertEqual(sideBySide.canonical(rect), rect)
        XCTAssertTrue(stacked.canonical(CGRect.null).isNull)
    }

    func testWindowsOneAboveTheOtherFormAStackedSeam() {
        let windows = [window(1, topHalf), window(2, bottomHalf)]
        let onSeam = CGPoint(x: 700, y: 462)

        let match = match(windows, at: onSeam, stacked)

        XCTAssertEqual(match?.leading.map { $0.id }, [1], "The window above")
        XCTAssertEqual(match?.trailing.map { $0.id }, [2], "The window below")
        XCTAssertEqual(match?.seam.position, 462, "How far down the seam is")
        XCTAssertEqual(match?.seam.span, 0...1440, "The seam runs the width of both")
        XCTAssertNil(self.match(windows, at: onSeam, sideBySide), "They are not side by side")
    }

    func testWindowsSideBySideAreNotAStackedSeam() {
        let windows = [window(1, CGRect(x: 0, y: 25, width: 720, height: 875)),
                       window(2, CGRect(x: 720, y: 25, width: 720, height: 875))]

        XCTAssertNil(match(windows, at: CGPoint(x: 720, y: 400), stacked))
        XCTAssertNotNil(match(windows, at: CGPoint(x: 720, y: 400), sideBySide))
    }

    func testStackedSeamAllowsForATerminalThatStoppedARowShort() {
        let shortTop = CGRect(x: 0, y: 25, width: 1440, height: 420)
        let windows = [window(1, shortTop), window(2, bottomHalf)]

        let match = match(windows, at: CGPoint(x: 700, y: 453), stacked)

        XCTAssertEqual(match?.seam.gap, 17)
        XCTAssertEqual(match?.seam.position, 453.5)
    }

    func testWindowsOnDisplaysOneAboveTheOtherDoNotMatch() {
        let upper = CGRect(x: 0, y: -900, width: 1440, height: 900)
        let windows = [window(1, CGRect(x: 0, y: -400, width: 1440, height: 400)),
                       window(2, CGRect(x: 0, y: 0, width: 1440, height: 450))]
        let boundary = CGPoint(x: 700, y: 0)

        XCTAssertNil(match(windows, at: boundary, stacked, in: screen))
        XCTAssertNil(match(windows, at: boundary, stacked, in: upper))
    }

    func testStackedSeamOnADisplayAboveTheMainOneMatches() {
        let upper = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
        let windows = [window(1, CGRect(x: 200, y: -1055, width: 1920, height: 527)),
                       window(2, CGRect(x: 200, y: -528, width: 1920, height: 528))]

        XCTAssertEqual(match(windows, at: CGPoint(x: 900, y: -528), stacked, in: upper)?.seam.position, -528)
    }

    func testMovingAStackedSeamChangesHeightsOnly() {
        let calls = FakeDividerWindow.Calls()
        let top = FakeDividerWindow("top", topHalf, calls: calls)
        let bottom = FakeDividerWindow("bottom", bottomHalf, calls: calls)
        let start = Frames(leading: [stacked.canonical(topHalf)], trailing: [stacked.canonical(bottomHalf)])
        let target = SnapDividerGeometry.resized(start, gap: 0, minimumLeadingWidths: [100],
                                                 minimumTrailingWidths: [100], seamAt: 300)

        let outcome = SnapDividerResize.apply(target, gap: 0,
                                              leading: [SnapDividerTransposedWindow(window: top)],
                                              trailing: [SnapDividerTransposedWindow(window: bottom)])

        XCTAssertEqual(top.frame, CGRect(x: 0, y: 25, width: 1440, height: 275))
        XCTAssertEqual(bottom.frame, CGRect(x: 0, y: 300, width: 1440, height: 600))
        XCTAssertEqual(outcome.final.map { stacked.canonical($0.trailing[0]) }, bottom.frame)
    }
}

final class SnapDividerGroupTests: XCTestCase {
    private typealias Frames = SnapDividerGeometry.Frames

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
    private let topRight = CGRect(x: 720, y: 25, width: 720, height: 437)
    private let bottomRight = CGRect(x: 720, y: 462, width: 720, height: 438)
    private let topLeft = CGRect(x: 0, y: 25, width: 720, height: 437)
    private let bottomLeft = CGRect(x: 0, y: 462, width: 720, height: 438)

    private func window(_ id: CGWindowID, _ frame: CGRect) -> WindowInfo {
        WindowInfo(id: id, level: kCGNormalWindowLevel, frame: frame, pid: pid_t(id), processName: "App \(id)", alpha: 1)
    }

    private func match(_ windows: [WindowInfo], at point: CGPoint, gap: CGFloat = 0,
                       _ arrangement: SnapDividerGeometry.Arrangement = .sideBySide) -> SnapDividerManager.Match? {
        SnapDividerManager.match(at: point, in: screen, windows: windows, configuredGap: gap, arrangement: arrangement)
    }

    func testLeftHalfFacingTwoRightQuartersIsOneSeamOfThreeWindows() {
        let windows = [window(1, leftHalf), window(2, topRight), window(3, bottomRight)]

        let match = match(windows, at: CGPoint(x: 720, y: 200))

        XCTAssertEqual(match?.leading.map { $0.id }, [1])
        XCTAssertEqual(match?.trailing.map { $0.id }, [2, 3], "In order down the seam")
        XCTAssertEqual(match?.seam.span, 25...900, "The seam runs the whole height of the half")
        XCTAssertEqual(match?.clearSpan, 25...900)
    }

    func testTheSameSeamIsFoundBesideEitherQuarter() {
        let windows = [window(3, bottomRight), window(1, leftHalf), window(2, topRight)]

        let besideTop = match(windows, at: CGPoint(x: 720, y: 200))
        let besideBottom = match(windows, at: CGPoint(x: 720, y: 700))

        XCTAssertNotNil(besideTop)
        XCTAssertEqual(besideBottom.map { besideTop?.isSame(as: $0) }, true)
    }

    func testQuartersWithGapsBetweenThemStillFormOneSeam() {
        let windows = [window(1, CGRect(x: 20, y: 45, width: 690, height: 835)),
                       window(2, CGRect(x: 730, y: 45, width: 690, height: 407)),
                       window(3, CGRect(x: 730, y: 472, width: 690, height: 408))]

        let match = match(windows, at: CGPoint(x: 720, y: 200), gap: 20)

        XCTAssertEqual(match?.trailing.map { $0.id }, [2, 3])
        XCTAssertEqual(match?.seam.gap, 20)
        XCTAssertEqual(match?.seam.span, 45...880)
    }

    func testSeamIsLookedUpAgainLevelWithWhereItWasFound() {
        // The middle of the seam is level with the space between the two
        // quarters, where there is no window on the right to find.
        let windows = [window(1, CGRect(x: 20, y: 45, width: 690, height: 835)),
                       window(2, CGRect(x: 730, y: 45, width: 690, height: 407)),
                       window(3, CGRect(x: 730, y: 472, width: 690, height: 408))]
        let found = match(windows, at: CGPoint(x: 716, y: 200), gap: 20)

        XCTAssertNil(match(windows, at: CGPoint(x: 720, y: 462), gap: 20))
        XCTAssertEqual(match(windows, at: CGPoint(x: 720, y: 200), gap: 20).map { found?.isSame(as: $0) }, true)
    }

    func testTwoLeftQuartersFacingARightHalf() {
        let windows = [window(1, topLeft), window(2, bottomLeft), window(3, CGRect(x: 720, y: 25, width: 720, height: 875))]

        let match = match(windows, at: CGPoint(x: 720, y: 700))

        XCTAssertEqual(match?.leading.map { $0.id }, [1, 2])
        XCTAssertEqual(match?.trailing.map { $0.id }, [3])
    }

    func testFourQuartersAreTwoSeamsOfTwoWindowsEach() {
        let windows = [window(1, topLeft), window(2, bottomLeft), window(3, topRight), window(4, bottomRight)]

        let upper = match(windows, at: CGPoint(x: 720, y: 200))
        let lower = match(windows, at: CGPoint(x: 720, y: 700))

        XCTAssertEqual(upper?.leading.map { $0.id }, [1])
        XCTAssertEqual(upper?.trailing.map { $0.id }, [3])
        XCTAssertEqual(lower?.leading.map { $0.id }, [2])
        XCTAssertEqual(lower?.trailing.map { $0.id }, [4])
    }

    func testWindowThatIsNotOnTheLineIsLeftOut() {
        let offLine = CGRect(x: 760, y: 462, width: 680, height: 438)
        let windows = [window(1, leftHalf), window(2, topRight), window(3, offLine)]

        let match = match(windows, at: CGPoint(x: 720, y: 200))

        XCTAssertEqual(match?.trailing.map { $0.id }, [2])
        XCTAssertEqual(match?.seam.span, 25...462)
    }

    func testWindowThatDoesNotFollowStraightOnIsLeftOut() {
        let further = CGRect(x: 720, y: 562, width: 720, height: 338)
        let windows = [window(1, leftHalf), window(2, topRight), window(3, further)]

        XCTAssertEqual(match(windows, at: CGPoint(x: 720, y: 200))?.trailing.map { $0.id }, [2])
    }

    func testCoveredQuarterIsLeftOut() {
        let cover = window(9, CGRect(x: 600, y: 462, width: 840, height: 438))
        let windows = [cover, window(1, leftHalf), window(2, topRight), window(3, bottomRight)]

        let match = match(windows, at: CGPoint(x: 720, y: 200))

        XCTAssertEqual(match?.trailing.map { $0.id }, [2])
        XCTAssertEqual(match?.clearSpan, 25...462)
    }

    func testTopHalfAboveTwoBottomQuartersIsOneStackedSeam() {
        let windows = [window(1, CGRect(x: 0, y: 25, width: 1440, height: 437)),
                       window(2, CGRect(x: 0, y: 462, width: 720, height: 438)),
                       window(3, CGRect(x: 720, y: 462, width: 720, height: 438))]

        let match = match(windows, at: CGPoint(x: 1000, y: 462), .stacked)

        XCTAssertEqual(match?.leading.map { $0.id }, [1])
        XCTAssertEqual(match?.trailing.map { $0.id }, [2, 3], "In order along the seam, left to right")
        XCTAssertEqual(match?.seam.span, 0...1440)
    }

    // MARK: Moving a seam of several windows

    private func frames() -> Frames {
        Frames(leading: [leftHalf], trailing: [topRight, bottomRight])
    }

    func testMovingTheSeamMovesEveryWindowOnIt() {
        let moved = SnapDividerGeometry.resized(frames(), gap: 0, minimumLeadingWidths: [150],
                                                minimumTrailingWidths: [150, 150], seamAt: 600)

        XCTAssertEqual(moved.leading, [CGRect(x: 0, y: 25, width: 600, height: 875)])
        XCTAssertEqual(moved.trailing, [CGRect(x: 600, y: 25, width: 840, height: 437),
                                        CGRect(x: 600, y: 462, width: 840, height: 438)])
    }

    func testSeamStopsAtTheLargestMinimumOnASide() {
        let moved = SnapDividerGeometry.resized(frames(), gap: 0, minimumLeadingWidths: [150],
                                                minimumTrailingWidths: [300, 500], seamAt: 1400)

        XCTAssertEqual(moved.seamPosition, 940)
        XCTAssertEqual(moved.trailing.map { $0.width }, [500, 500])
    }

    func testWindowsOnOneSideKeepTheirOwnOuterEdges() {
        let uneven = Frames(leading: [CGRect(x: 0, y: 25, width: 720, height: 437),
                                      CGRect(x: 240, y: 462, width: 480, height: 438)],
                            trailing: [CGRect(x: 720, y: 25, width: 720, height: 875)])

        let moved = SnapDividerGeometry.resized(uneven, gap: 0, minimumLeadingWidths: [150, 150],
                                                minimumTrailingWidths: [150], seamAt: 800)

        XCTAssertEqual(moved.leading, [CGRect(x: 0, y: 25, width: 800, height: 437),
                                       CGRect(x: 240, y: 462, width: 560, height: 438)])
    }

    func testResizingMovesAllThreeWindowsToTheSameLine() {
        let calls = FakeDividerWindow.Calls()
        let left = FakeDividerWindow("left", leftHalf, calls: calls)
        let top = FakeDividerWindow("top", topRight, calls: calls)
        let bottom = FakeDividerWindow("bottom", bottomRight, calls: calls)
        let target = SnapDividerGeometry.resized(frames(), gap: 0, minimumLeadingWidths: [150],
                                                 minimumTrailingWidths: [150, 150], seamAt: 600)

        let outcome = SnapDividerResize.apply(target, gap: 0, leading: [left], trailing: [top, bottom])

        XCTAssertEqual(outcome.final, target)
        XCTAssertFalse(outcome.wasRevised)
        XCTAssertEqual(calls.made, ["top size", "top position", "bottom size", "bottom position", "left size"],
                       "The side that grows goes first")
    }

    func testWhenOneWindowWillNotShrinkTheOthersEndOnItsLine() {
        let calls = FakeDividerWindow.Calls()
        let left = FakeDividerWindow("left", leftHalf, calls: calls)
        let top = FakeDividerWindow("top", topRight, calls: calls) { max($0, 600) }
        let bottom = FakeDividerWindow("bottom", bottomRight, calls: calls)
        let target = SnapDividerGeometry.resized(frames(), gap: 0, minimumLeadingWidths: [150],
                                                 minimumTrailingWidths: [150, 150], seamAt: 1200)

        let outcome = SnapDividerResize.apply(target, gap: 0, leading: [left], trailing: [top, bottom])

        XCTAssertEqual(outcome.final?.leading, [CGRect(x: 0, y: 25, width: 840, height: 875)])
        XCTAssertEqual(outcome.final?.trailing, [CGRect(x: 840, y: 25, width: 600, height: 437),
                                                 CGRect(x: 840, y: 462, width: 600, height: 438)],
                       "The quarter that could have shrunk further comes back to the one that could not")
        XCTAssertTrue(outcome.wasRevised)
    }

    func testCautiouslyNoWindowIsGrownOverOneThatWillNotShrink() {
        let calls = FakeDividerWindow.Calls()
        let left = FakeDividerWindow("left", leftHalf, calls: calls)
        let top = FakeDividerWindow("top", topRight, calls: calls) { max($0, 600) }
        let bottom = FakeDividerWindow("bottom", bottomRight, calls: calls)
        left.neighbour = top
        let target = SnapDividerGeometry.resized(frames(), gap: 0, minimumLeadingWidths: [150],
                                                 minimumTrailingWidths: [150, 150], seamAt: 1200)

        let outcome = SnapDividerResize.apply(target, gap: 0, leading: [left], trailing: [top, bottom], cautious: true)

        XCTAssertEqual(outcome.final?.seamPosition, 840)
        XCTAssertEqual(left.widthsAsked, [840])
        XCTAssertEqual(left.worstOverlap, 0)
    }
}

final class SnapDividerDragToSnapTests: XCTestCase {
    private final class Manager: SnappingManager {
        var begunDrags = 0
        @discardableResult
        override func beginNativeDrag() -> UUID {
            begunDrags += 1
            return super.beginNativeDrag()
        }
    }

    private var savedSnapping: Bool?
    private var savedObtainOnClick: Bool?

    override func setUp() {
        super.setUp()
        savedSnapping = Defaults.windowSnapping.enabled
        savedObtainOnClick = Defaults.obtainWindowOnClick.enabled
        Defaults.windowSnapping.enabled = false
        // Keeps a tracked mouse-down away from the accessibility hit-test under the cursor.
        Defaults.obtainWindowOnClick.enabled = false
    }

    override func tearDown() {
        Defaults.windowSnapping.enabled = savedSnapping
        Defaults.obtainWindowOnClick.enabled = savedObtainOnClick
        super.tearDown()
    }

    /// A mouse event as the window server reports it, on the window with the given number.
    private func mouse(_ type: CGEventType, onWindow windowNumber: Int) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                            mouseCursorPosition: CGPoint(x: 720, y: 400), mouseButton: .left))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    func testAPressOnTheHandleIsItsTarget() throws {
        let handle = SnapDividerPanel()
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false

        XCTAssertTrue(SnapDividerPanel.isTarget(of: try mouse(.leftMouseDown, onWindow: handle.windowNumber)))
        XCTAssertFalse(SnapDividerPanel.isTarget(of: try mouse(.leftMouseDown, onWindow: other.windowNumber)),
                       "Another of Rectangle's own windows")
        XCTAssertFalse(SnapDividerPanel.isTarget(of: try mouse(.leftMouseDown, onWindow: 0)),
                       "A window of another app, or none")
    }

    func testAPressOnTheHandleIsFoundThroughTheEventsOwnWindowToo() throws {
        let handle = SnapDividerPanel()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: handle.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))

        XCTAssertTrue(SnapDividerPanel.isTarget(of: event))
    }

    func testDragToSnapLeavesADragOfTheHandleAlone() throws {
        let handle = SnapDividerPanel()
        let manager = Manager()

        manager.handle(event: try mouse(.leftMouseDown, onWindow: handle.windowNumber))
        XCTAssertEqual(manager.begunDrags, 0)
        manager.handle(event: try mouse(.leftMouseDragged, onWindow: handle.windowNumber))
        XCTAssertEqual(manager.windowIdAttempt, 0, "no window lookup during the drag")
        XCTAssertNil(manager.windowElement)
        XCTAssertFalse(manager.windowMoving)
        manager.handle(event: try mouse(.leftMouseUp, onWindow: handle.windowNumber))
        XCTAssertEqual(manager.begunDrags, 0)
    }

    func testDragToSnapTracksTheNextGestureAsUsual() throws {
        let handle = SnapDividerPanel()
        let manager = Manager()

        manager.handle(event: try mouse(.leftMouseDown, onWindow: handle.windowNumber))
        manager.handle(event: try mouse(.leftMouseUp, onWindow: handle.windowNumber))
        manager.handle(event: try mouse(.leftMouseDown, onWindow: 0))
        XCTAssertEqual(manager.begunDrags, 1, "the ignored press does not carry over")
        manager.handle(event: try mouse(.leftMouseUp, onWindow: 0))
    }
}

