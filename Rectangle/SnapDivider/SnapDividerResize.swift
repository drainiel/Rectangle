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
        /// The frames asked for.
        let requested: SnapDividerGeometry.Frames
        /// Where the windows ended up, or nil if they could not be read.
        let final: SnapDividerGeometry.Frames?

        /// Whether a window took a different width than it was asked for,
        /// so that the seam is not where it was put.
        var wasRevised: Bool {
            guard let final else { return false }
            return abs(final.left.width - requested.left.width) > tolerance
                || abs(final.right.width - requested.right.width) > tolerance
        }
    }

    /// Frames this close are the same frame: nothing is written for less.
    static let tolerance: CGFloat = 1

    /// Resizes the two windows towards `target`, so that they end with `gap`
    /// between them, no overlap and no stray space. The left window keeps
    /// its left edge and the right window its right edge. Nothing vertical is
    /// touched.
    ///
    /// An app can refuse a size: it will not go below a minimum it never
    /// reported, or it only resizes in steps. So the windows are asked one
    /// after the other, and the second is asked for what the first left. If
    /// it does not take exactly that, the first is asked once more, for what
    /// the second left.
    ///
    /// Which goes first is a matter of what shows on the way. Normally it is
    /// the window that grows: for a moment it lies over the edge of the one
    /// about to shrink, which cannot be seen, where the other order opens a
    /// strip of desktop between the two at every step. With `cautious` it is
    /// the window that gives up space, and the other only gets what was
    /// really given up. That is the order to use once a window has refused a
    /// size, because a window growing over a neighbour that will not shrink
    /// has to be pulled back again each time.
    ///
    /// `known` is where the windows were last read, which saves reading them
    /// again when one resize follows another.
    static func apply(_ target: SnapDividerGeometry.Frames, gap: CGFloat,
                      left: SnapDividerWindow, right: SnapDividerWindow,
                      from known: SnapDividerGeometry.Frames? = nil,
                      cautious: Bool = false) -> Outcome {
        guard var current = known ?? read(left, right) else {
            return Outcome(requested: target, final: nil)
        }
        let gap = max(0, gap)
        let leftEdge = target.left.minX
        let rightEdge = target.right.maxX
        /// The width the two windows have to share.
        let room = rightEdge - leftEdge - gap

        /// Asks the left window for a width. False if it could not be read
        /// back afterwards.
        func resizeLeft(to width: CGFloat) -> Bool {
            var wrote = false
            if abs(current.left.minX - leftEdge) > tolerance {
                left.setPosition(CGPoint(x: leftEdge, y: current.left.minY))
                wrote = true
            }
            if abs(current.left.width - width) > tolerance {
                left.setSize(CGSize(width: width, height: current.left.height))
                wrote = true
            }
            guard wrote else { return true }
            guard let frame = left.frame else { return false }
            current.left = frame
            return true
        }

        /// Asks the right window for a width, with its right edge held.
        ///
        /// Position and size can only be set one after the other, so for a
        /// moment the window is in neither frame. The order is chosen so
        /// that it then reaches past its right edge, which at the edge of
        /// the screen cannot be seen, and never falls short of it, which
        /// would show what is behind: a window that shrinks is moved first,
        /// one that grows is resized first.
        func resizeRight(to width: CGFloat) -> Bool {
            var frame = current.right
            func readBack() -> Bool {
                guard let read = right.frame else { return false }
                frame = read
                return true
            }
            func move(toWidth width: CGFloat) {
                right.setPosition(CGPoint(x: rightEdge - width, y: frame.minY))
            }
            func resize() {
                right.setSize(CGSize(width: width, height: frame.height))
            }

            if width < frame.width - tolerance {
                move(toWidth: width)
                resize()
                guard readBack() else { return false }
            } else if width > frame.width + tolerance {
                resize()
                guard readBack() else { return false }
                if frame.width < width - tolerance {
                    // It came out short. A window is not always let reach
                    // past the edge of the screen, and where it is going it
                    // has the room. (One that resizes in steps just gives
                    // the same answer again.)
                    move(toWidth: width)
                    resize()
                    guard readBack() else { return false }
                }
            }
            // Whatever width it took, its right edge goes back where it was.
            if abs(frame.maxX - rightEdge) > tolerance {
                move(toWidth: frame.width)
                guard readBack() else { return false }
            }
            current.right = frame
            return true
        }

        func rest(besides width: CGFloat) -> CGFloat { max(1, room - width) }
        func took(_ width: CGFloat, _ offered: CGFloat) -> Bool { abs(width - offered) <= tolerance }

        let leftGivesWay = target.left.width <= current.left.width
        let readable: Bool
        if leftGivesWay == cautious {
            readable = resizeLeft(to: target.left.width)
                && resizeRight(to: rest(besides: current.left.width))
                && (took(current.right.width, rest(besides: current.left.width))
                    || resizeLeft(to: rest(besides: current.right.width)))
        } else {
            readable = resizeRight(to: target.right.width)
                && resizeLeft(to: rest(besides: current.right.width))
                && (took(current.left.width, rest(besides: current.right.width))
                    || resizeRight(to: rest(besides: current.left.width)))
        }
        guard readable else { return Outcome(requested: target, final: nil) }

        // Two windows that both chose their own width leave space over. It
        // goes to the far right, not between them: a position is never
        // refused, so the right window can always be slid up to the left one.
        if current.right.minX - (current.left.maxX + gap) > tolerance {
            right.setPosition(CGPoint(x: current.left.maxX + gap, y: current.right.minY))
            guard let moved = right.frame else { return Outcome(requested: target, final: nil) }
            current.right = moved
        }
        return Outcome(requested: target, final: current)
    }

    private static func read(_ left: SnapDividerWindow, _ right: SnapDividerWindow) -> SnapDividerGeometry.Frames? {
        guard let leftFrame = left.frame, let rightFrame = right.frame else { return nil }
        return SnapDividerGeometry.Frames(left: leftFrame, right: rightFrame)
    }
}

/// The resizing done over one drag of the handle.
///
/// Seam positions arrive as fast as the mouse moves, and applying one can
/// take an app a while. They are applied one at a time, and while one is
/// being applied only the latest of those that follow is kept: the windows
/// skip ahead to where the pointer is now, and a slow app never builds up a
/// backlog to work through after the drag has ended.
///
/// `request`, `finish` and `cancel` are called on the main thread. The
/// windows are only ever touched from `work`.
final class SnapDividerResizeSession {
    typealias Frames = SnapDividerGeometry.Frames

    private let left: SnapDividerWindow
    private let right: SnapDividerWindow
    private let gap: CGFloat
    private let work: (@escaping () -> Void) -> Void
    private let reply: (@escaping () -> Void) -> Void
    private let begin: () -> () -> Void

    // Main thread.
    private var pending: Frames?
    private var isWorking = false
    private var known: Frames?
    /// Whether a window took a different width than asked last time.
    private var cautious = false
    private var lastOutcome: SnapDividerResize.Outcome?
    private var completion: ((SnapDividerResize.Outcome?) -> Void)?
    private var hasEnded = false

    // `work` only.
    private var end: (() -> Void)?

    /// - Parameters:
    ///   - work: Runs a block where the windows may be written, one block at
    ///     a time and in order.
    ///   - reply: Runs a block back on the main thread.
    ///   - begin: Called from `work` before the first resize. What it returns
    ///     is called from `work` after the last one.
    init(left: SnapDividerWindow, right: SnapDividerWindow, gap: CGFloat,
         work: @escaping (@escaping () -> Void) -> Void,
         reply: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         begin: @escaping () -> () -> Void = { {} }) {
        self.left = left
        self.right = right
        self.gap = gap
        self.work = work
        self.reply = reply
        self.begin = begin
    }

    /// Asks for the windows to be resized to `target`, in place of anything
    /// asked for earlier that has not been started.
    func request(_ target: Frames) {
        guard !hasEnded else { return }
        pending = target
        proceed()
    }

    /// Ends the session. `completion` is called on the main thread once the
    /// last request has been applied, with what the windows did then - nil
    /// if nothing was ever asked for.
    func finish(_ completion: @escaping (SnapDividerResize.Outcome?) -> Void) {
        guard !hasEnded else { return }
        hasEnded = true
        self.completion = completion
        proceed()
    }

    /// Ends the session without applying what has not been started.
    func cancel() {
        pending = nil
        finish { _ in }
    }

    private func proceed() {
        guard !isWorking else { return }
        if let target = pending {
            pending = nil
            isWorking = true
            let known = self.known
            let cautious = self.cautious
            work { [self] in
                if end == nil { end = begin() }
                let outcome = SnapDividerResize.apply(target, gap: gap, left: left, right: right,
                                                      from: known, cautious: cautious)
                reply { [self] in
                    isWorking = false
                    self.known = outcome.final
                    self.cautious = outcome.wasRevised
                    lastOutcome = outcome
                    proceed()
                }
            }
        } else if let completion {
            self.completion = nil
            isWorking = true
            work { [self] in
                end?()
                end = nil
                reply { [self] in
                    isWorking = false
                    completion(lastOutcome)
                }
            }
        }
    }
}
