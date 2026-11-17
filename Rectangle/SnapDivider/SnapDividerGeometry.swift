/// SnapDividerGeometry.swift

import Foundation

/// Pure geometry for the snap divider: whether two window frames meet along a
/// shared edge, and whether a point is resting on that edge.
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
}
