/// SnapDividerResize.swift

import Cocoa

/// One of the two windows on a seam, as far as resizing it goes. Every call
/// goes to the window's app and blocks until the app has answered.
protocol SnapDividerWindow {
    /// Where the window is now, or nil if its app did not say.
    var frame: CGRect? { get }
    func setPosition(_ position: CGPoint)
    func setSize(_ size: CGSize)
}

/// A real window, reached through accessibility.
///
/// This goes to the element directly instead of through
/// `AccessibilityElement.setFrame`: that writes three times and reads back
/// after each write for the log, and it logs, which only the main thread may
/// do. The resize runs off the main thread.
struct SnapDividerAXWindow: SnapDividerWindow {
    let element: AXUIElement

    var frame: CGRect? {
        guard let position: CGPoint = element.getWrappedValue(.position, type: .cgPoint),
              let size: CGSize = element.getWrappedValue(.size, type: .cgSize)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    func setPosition(_ position: CGPoint) {
        element.setValue(.position, position)
    }

    func setSize(_ size: CGSize) {
        element.setValue(.size, size)
    }
}

/// Moves the seam between two real windows.
enum SnapDividerResize {

    struct Outcome {
        /// The frames first asked for.
        let requested: SnapDividerGeometry.Frames
        /// What was asked for after the windows had answered, when that was
        /// something else: one of them refused the size it was given.
        let corrected: SnapDividerGeometry.Frames?
        /// Where the windows ended up, or nil if they could not be read.
        let final: SnapDividerGeometry.Frames?
    }

    /// Asks both windows for `target`, reads back what they did, and asks
    /// once more if one of them took a different size, so that the pair ends
    /// with `gap` between them, no overlap and no stray space.
    static func apply(_ target: SnapDividerGeometry.Frames, gap: CGFloat,
                      left: SnapDividerWindow, right: SnapDividerWindow) -> Outcome {
        guard let before = read(left, right) else {
            return Outcome(requested: target, corrected: nil, final: nil)
        }
        write(target, from: before, left: left, right: right)

        guard let actual = read(left, right) else {
            return Outcome(requested: target, corrected: nil, final: nil)
        }
        let corrected = SnapDividerGeometry.reconciled(requested: target, actual: actual, gap: gap,
                                                       tolerance: tolerance)
        guard differs(corrected.left, actual.left) || differs(corrected.right, actual.right) else {
            return Outcome(requested: target, corrected: nil, final: actual)
        }
        write(corrected, from: actual, left: left, right: right)
        return Outcome(requested: target, corrected: corrected, final: read(left, right))
    }

    private static func read(_ left: SnapDividerWindow, _ right: SnapDividerWindow) -> SnapDividerGeometry.Frames? {
        guard let leftFrame = left.frame, let rightFrame = right.frame else { return nil }
        return SnapDividerGeometry.Frames(left: leftFrame, right: rightFrame)
    }

    /// The window that gives up space goes first, so the two never overlap
    /// on the way.
    private static func write(_ frames: SnapDividerGeometry.Frames, from current: SnapDividerGeometry.Frames,
                              left: SnapDividerWindow, right: SnapDividerWindow) {
        if frames.left.width <= current.left.width {
            place(left, at: frames.left, from: current.left)
            place(right, at: frames.right, from: current.right)
        } else {
            place(right, at: frames.right, from: current.right)
            place(left, at: frames.left, from: current.left)
        }
    }

    /// Position and size can only be set one after the other. A window that
    /// shrinks is resized before it is moved and one that grows is moved
    /// first, which keeps it inside the larger of its two frames throughout.
    private static func place(_ window: SnapDividerWindow, at frame: CGRect, from current: CGRect) {
        let moves = abs(frame.minX - current.minX) > tolerance || abs(frame.minY - current.minY) > tolerance
        let resizes = abs(frame.width - current.width) > tolerance || abs(frame.height - current.height) > tolerance
        if frame.width < current.width {
            if resizes { window.setSize(frame.size) }
            if moves { window.setPosition(frame.origin) }
        } else {
            if moves { window.setPosition(frame.origin) }
            if resizes { window.setSize(frame.size) }
        }
    }

    /// Frames this close are the same frame: nothing is written for less.
    private static let tolerance: CGFloat = 1

    private static func differs(_ frame: CGRect, _ other: CGRect) -> Bool {
        abs(frame.minX - other.minX) > tolerance || abs(frame.minY - other.minY) > tolerance
            || abs(frame.width - other.width) > tolerance || abs(frame.height - other.height) > tolerance
    }
}
