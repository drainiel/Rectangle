/// SnapDividerGeometry.swift

import Foundation

/// Pure geometry for the snap divider: whether two window frames meet along a
/// shared edge, whether a point is resting on that edge, and where the
/// frames go when the edge is moved.
/// No AppKit, no AX - computable from frames alone. Frames and points use the
/// window list's coordinates (top-left origin, y down).
///
/// Everything is worked out for windows side by side, with a vertical seam
/// between them. Windows stacked one above the other are the same problem
/// with x and y changed round, and `Arrangement` does the changing on the way
/// in and on the way out.
enum SnapDividerGeometry {

    /// How the windows on a seam lie.
    enum Arrangement: Equatable {
        /// Left and right of a vertical seam, which is dragged sideways.
        case sideBySide
        /// Above and below a horizontal seam, which is dragged up and down.
        case stacked

        /// Takes a frame to the side-by-side geometry everything here is
        /// worked out in, or back from it: for stacked windows x and y change
        /// places, so that left stands for above and right for below. Doing
        /// it twice gives the original.
        func canonical(_ rect: CGRect) -> CGRect {
            guard self == .stacked, !rect.isNull else { return rect }
            return CGRect(x: rect.origin.y, y: rect.origin.x, width: rect.size.height, height: rect.size.width)
        }

        func canonical(_ point: CGPoint) -> CGPoint {
            self == .stacked ? CGPoint(x: point.y, y: point.x) : point
        }

        func canonical(_ size: CGSize) -> CGSize {
            self == .stacked ? CGSize(width: size.height, height: size.width) : size
        }
    }

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

    /// The parts of `range` that none of `holes` reaches into.
    static func remainder(of range: ClosedRange<CGFloat>,
                          without holes: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        holes.reduce([range]) { parts, hole in
            parts.flatMap { part -> [ClosedRange<CGFloat>] in
                guard hole.overlaps(part) else { return [part] }
                var left = [ClosedRange<CGFloat>]()
                if hole.lowerBound > part.lowerBound { left.append(part.lowerBound...hole.lowerBound) }
                if hole.upperBound < part.upperBound { left.append(hole.upperBound...part.upperBound) }
                return left
            }
        }
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

    /// The frames of the windows on a seam: the ones to its left, whose right
    /// edges it moves, and the ones to its right. Usually one of each. There
    /// are more where several windows line up along one side, such as a left
    /// half facing two right quarters.
    struct Frames: Equatable {
        var leading: [CGRect]
        var trailing: [CGRect]

        /// How far right the windows on the left reach.
        var leadingEdge: CGFloat { leading.map { $0.maxX }.max() ?? 0 }
        /// Where the windows on the right begin.
        var trailingEdge: CGFloat { trailing.map { $0.minX }.min() ?? 0 }
        /// The middle of the space between the two sides.
        var seamPosition: CGFloat { (leadingEdge + trailingEdge) / 2 }
    }

    /// The gap a moved seam should leave between the two windows, given how
    /// far apart their facing edges are now.
    ///
    /// Two things are taken to be the configured gap gone wrong, and are put
    /// right: windows that overlap, because one would not shrink, and windows
    /// up to `tolerance` further apart than the gap, because one stopped
    /// short of its edge. Anything else was arranged that way and is kept,
    /// such as windows touching while a gap is configured.
    static func intendedGap(distance: CGFloat, configuredGap: CGFloat, tolerance: CGFloat) -> CGFloat {
        let configuredGap = max(0, configuredGap)
        let overlaps = distance < 0
        let stoppedShort = distance > configuredGap && distance <= configuredGap + tolerance
        return overlaps || stoppedShort ? configuredGap : distance
    }

    /// The frames after the seam is moved to `position`, the middle of the
    /// gap. Every window keeps its outer edge - the left edge for those on
    /// the left, the right edge for those on the right - and everything
    /// vertical.
    ///
    /// The seam goes no further than leaves each window its minimum width.
    /// If the minimums do not fit side by side, nothing moves. The facing
    /// edges land on whole points.
    static func resized(_ frames: Frames, gap: CGFloat,
                        minimumLeadingWidths: [CGFloat], minimumTrailingWidths: [CGFloat],
                        seamAt position: CGFloat) -> Frames {
        let gap = max(0, gap)
        guard frames.leading.count == minimumLeadingWidths.count,
              frames.trailing.count == minimumTrailingWidths.count,
              (frames.leading + frames.trailing).allSatisfy({ $0.isValidWindowFrame }),
              position.isFinite,
              let lowest = zip(frames.leading, minimumLeadingWidths).map({ $0.minX + max(1, $1) }).max(),
              let highest = zip(frames.trailing, minimumTrailingWidths).map({ $0.maxX - max(1, $1) - gap }).min(),
              lowest <= highest
        else { return frames }

        let leadingEdge = min(max((position - gap / 2).rounded(), lowest), highest)
        var resized = frames
        for index in resized.leading.indices {
            resized.leading[index].size.width = leadingEdge - resized.leading[index].minX
        }
        for index in resized.trailing.indices {
            let farEdge = resized.trailing[index].maxX
            resized.trailing[index].origin.x = leadingEdge + gap
            resized.trailing[index].size.width = farEdge - (leadingEdge + gap)
        }
        return resized
    }
}
