/// SnapDividerGeometry.swift

import Foundation

/// Pure geometry for the snap divider: whether two window frames meet along a
/// shared edge, whether a point is resting on that edge, and where the two
/// frames go when the edge is moved.
/// No AppKit, no AX - computable from frames alone. Frames and points use the
/// window list's coordinates (top-left origin, y down).
enum SnapDividerGeometry {

    /// The shared edge between a window and the window to its right.
    struct Seam: Equatable {
        /// Where the divider sits: midway between the two facing edges, so it
        /// is centred in a gap and on the line when the windows touch.
        let position: CGFloat
        /// The space between the facing edges. Zero when the windows touch or
        /// overlap slightly.
        let gap: CGFloat
        /// The stretch along the edge that both windows cover.
        let span: ClosedRange<CGFloat>

        /// Whether a point rests on the seam: inside the gap or within `slop`
        /// of it, and inside the stretch both windows cover.
        func isNear(_ point: CGPoint, slop: CGFloat) -> Bool {
            abs(point.x - position) <= gap / 2 + slop && span.contains(point.y)
        }
    }

    /// The seam between `left` and `right`, or nil when they are not side by
    /// side.
    ///
    /// Snapped windows rarely meet exactly. A configured gap separates them,
    /// an app that resizes in steps stops short of the edge it was given, and
    /// one that refuses to go below its minimum size reaches past it. So the
    /// facing edges may be up to `maxGap` apart or overlap by `maxOverlap`.
    ///
    /// `minimumSpan` is how much of the edge the two must share, which keeps
    /// windows that only meet near a corner from counting.
    static func seam(left: CGRect, right: CGRect,
                     maxGap: CGFloat, maxOverlap: CGFloat,
                     minimumSpan: CGFloat) -> Seam? {
        guard left.isValidWindowFrame, right.isValidWindowFrame,
              // A sliver narrower than the allowed overlap could otherwise
              // lie wholly inside the other window's edge and still pass.
              left.minX < right.minX, left.maxX < right.maxX
        else { return nil }

        let distance = right.minX - left.maxX
        guard distance <= maxGap, -distance <= maxOverlap else { return nil }

        let spanStart = max(left.minY, right.minY)
        let spanEnd = min(left.maxY, right.maxY)
        guard spanEnd - spanStart >= max(minimumSpan, 0) else { return nil }

        return Seam(position: (left.maxX + right.minX) / 2,
                    gap: max(0, distance),
                    span: spanStart...spanEnd)
    }

    /// The part of `span` around `coordinate` that nothing in `blocked`
    /// reaches into, or nil when `coordinate` is itself blocked or lies
    /// outside the span. This is the stretch of a seam the user can see when
    /// other windows cover parts of it.
    static func clearStretch(of span: ClosedRange<CGFloat>, around coordinate: CGFloat,
                             blockedBy blocked: [ClosedRange<CGFloat>]) -> ClosedRange<CGFloat>? {
        guard span.contains(coordinate) else { return nil }
        var lower = span.lowerBound
        var upper = span.upperBound
        for range in blocked {
            if range.contains(coordinate) { return nil }
            if range.upperBound < coordinate {
                lower = max(lower, range.upperBound)
            } else {
                upper = min(upper, range.lowerBound)
            }
        }
        return lower...upper
    }

    /// Where the handle is drawn: centred on the seam and on `stretch`,
    /// covering `lengthFraction` of it. The length never drops below
    /// `minimumLength` unless the stretch itself is shorter. The frame lands
    /// on whole points.
    static func handleFrame(on seam: Seam, within stretch: ClosedRange<CGFloat>,
                            thickness: CGFloat, lengthFraction: CGFloat,
                            minimumLength: CGFloat) -> CGRect {
        let available = stretch.upperBound - stretch.lowerBound
        let length = min(available, max(minimumLength, available * lengthFraction)).rounded()
        let middle = (stretch.lowerBound + stretch.upperBound) / 2
        return CGRect(x: (seam.position - thickness / 2).rounded(),
                      y: (middle - length / 2).rounded(),
                      width: thickness,
                      height: length)
    }

    // MARK: Moving the seam

    /// The frames of the two windows on a seam.
    struct Frames: Equatable {
        var left: CGRect
        var right: CGRect

        /// The middle of the space between the two.
        var seamPosition: CGFloat { (left.maxX + right.minX) / 2 }
    }

    /// The gap a moved seam should leave between the two windows, given how
    /// far apart their facing edges are now.
    ///
    /// A distance close to the configured gap is taken to be that gap gone
    /// slightly wrong - a window that stopped short of its edge, or reached a
    /// little past it - and is put right. Anything else was arranged that
    /// way, such as windows touching while a gap is configured, and is kept.
    static func intendedGap(distance: CGFloat, configuredGap: CGFloat, tolerance: CGFloat) -> CGFloat {
        let configuredGap = max(0, configuredGap)
        return abs(distance - configuredGap) <= tolerance ? configuredGap : max(0, distance)
    }

    /// The two frames after the seam between them is moved to `position`,
    /// the middle of the gap. The left window's left edge and the right
    /// window's right edge stay where they are, as does everything vertical.
    ///
    /// The seam goes no further than leaves each window its minimum width.
    /// If the two minimums do not fit side by side, nothing moves. The facing
    /// edges land on whole points.
    static func resized(_ frames: Frames, gap: CGFloat,
                        minimumLeftWidth: CGFloat, minimumRightWidth: CGFloat,
                        seamAt position: CGFloat) -> Frames {
        let gap = max(0, gap)
        let lowest = frames.left.minX + max(1, minimumLeftWidth)
        let highest = frames.right.maxX - max(1, minimumRightWidth) - gap
        guard frames.left.isValidWindowFrame, frames.right.isValidWindowFrame,
              position.isFinite, lowest <= highest
        else { return frames }

        let leftEdge = min(max((position - gap / 2).rounded(), lowest), highest)
        return placed(frames, leftWidth: leftEdge - frames.left.minX, gap: gap)
    }

    /// What to ask of the two windows once it is known what they did with
    /// the frames first asked of them.
    ///
    /// An app can refuse a size: it will not go below a minimum it never
    /// reported, or it only resizes in steps. A window that came out a
    /// different width than asked keeps the width it chose, and the other
    /// one takes up the difference, so the two still meet with `gap` between
    /// them and the pair still spans from the left window's left edge to the
    /// right window's right edge. If both chose their own width, the left one
    /// wins and the right one is asked again for what is left over.
    static func reconciled(requested: Frames, actual: Frames, gap: CGFloat, tolerance: CGFloat = 1) -> Frames {
        let gap = max(0, gap)
        let span = requested.right.maxX - requested.left.minX
        let leftRefused = abs(actual.left.width - requested.left.width) > tolerance
        let rightRefused = abs(actual.right.width - requested.right.width) > tolerance

        var leftWidth = requested.left.width
        if leftRefused {
            leftWidth = actual.left.width
        } else if rightRefused {
            leftWidth = span - gap - actual.right.width
        }
        // Nothing sensible is left for one of them: stay with what was asked.
        guard leftWidth >= 1, span - gap - leftWidth >= 1 else { return requested }
        return placed(requested, leftWidth: leftWidth, gap: gap)
    }

    /// `frames` with the left window `leftWidth` wide and the right one
    /// starting `gap` after it, both far edges unmoved.
    private static func placed(_ frames: Frames, leftWidth: CGFloat, gap: CGFloat) -> Frames {
        var placed = frames
        placed.left.size.width = leftWidth
        placed.right.origin.x = frames.left.minX + leftWidth + gap
        placed.right.size.width = frames.right.maxX - placed.right.origin.x
        return placed
    }
}
