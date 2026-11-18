/// SnapDividerResize.swift

import Cocoa

/// One of the windows on a seam, as far as resizing it goes. Every call
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

/// A window seen with x and y changed round, which makes two windows stacked
/// one above the other look like two side by side. See
/// `SnapDividerGeometry.Arrangement`.
struct SnapDividerTransposedWindow: SnapDividerWindow {
    let window: SnapDividerWindow

    var frame: CGRect? {
        window.frame.map { SnapDividerGeometry.Arrangement.stacked.canonical($0) }
    }

    func setPosition(_ position: CGPoint) {
        window.setPosition(SnapDividerGeometry.Arrangement.stacked.canonical(position))
    }

    func setSize(_ size: CGSize) {
        window.setSize(SnapDividerGeometry.Arrangement.stacked.canonical(size))
    }
}

/// Moves the seam between real windows.
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
            return zip(final.leading + final.trailing, requested.leading + requested.trailing).contains {
                abs($0.width - $1.width) > tolerance
            }
        }
    }

    /// Frames this close are the same frame: nothing is written for less.
    static let tolerance: CGFloat = 1

    /// Resizes the windows towards `target`, so that the two sides end with
    /// `gap` between them, no overlap and no stray space. Each window keeps
    /// its outer edge: the left edge for those on the left of the seam, the
    /// right edge for those on the right. Nothing vertical is touched.
    ///
    /// An app can refuse a size: it will not go below a minimum it never
    /// reported, or it only resizes in steps. So the two sides are asked one
    /// after the other, and what the first side did decides where the second
    /// is asked to meet it. A window that would not shrink holds the seam
    /// where it stopped, and one that grew less than asked draws the seam
    /// back to itself. Whenever the seam has had to move, both sides are
    /// gone over again, so that every window ends on the same line.
    ///
    /// Which side goes first is a matter of what shows on the way. Normally
    /// it is the side that grows: for a moment it lies over the edge of the
    /// side about to shrink, which cannot be seen, where the other order
    /// opens a strip of desktop between the two at every step. With
    /// `cautious` it is the side that gives up space, and the other only gets
    /// what was really given up. That is the order to use once a window has
    /// refused a size, because a window growing over a neighbour that will
    /// not shrink has to be pulled back again each time.
    ///
    /// `known` is where the windows were last read, which saves reading them
    /// again when one resize follows another.
    static func apply(_ target: SnapDividerGeometry.Frames, gap: CGFloat,
                      leading: [SnapDividerWindow], trailing: [SnapDividerWindow],
                      from known: SnapDividerGeometry.Frames? = nil,
                      cautious: Bool = false) -> Outcome {
        let unreadable = Outcome(requested: target, final: nil)
        guard !leading.isEmpty, !trailing.isEmpty,
              leading.count == target.leading.count, trailing.count == target.trailing.count,
              var current = known ?? read(leading, trailing),
              current.leading.count == leading.count, current.trailing.count == trailing.count
        else { return unreadable }
        let gap = max(0, gap)
        /// Where the windows on the left are to end. Those on the right
        /// begin `gap` after it.
        var line = target.leadingEdge

        /// Puts the right edge of a window on the left of the seam on the
        /// line. False if the window could not be read back afterwards.
        func settleLeading(_ index: Int) -> Bool {
            let window = leading[index]
            let outerEdge = target.leading[index].minX
            let width = max(1, line - outerEdge)
            let frame = current.leading[index]
            var wrote = false
            if abs(frame.minX - outerEdge) > tolerance {
                window.setPosition(CGPoint(x: outerEdge, y: frame.minY))
                wrote = true
            }
            if abs(frame.width - width) > tolerance {
                window.setSize(CGSize(width: width, height: frame.height))
                wrote = true
            }
            guard wrote else { return true }
            guard let read = window.frame else { return false }
            current.leading[index] = read
            return true
        }

        /// Puts the left edge of a window on the right of the seam `gap`
        /// after the line, with its right edge held.
        ///
        /// Position and size can only be set one after the other, so for a
        /// moment the window is in neither frame. The order is chosen so
        /// that it then reaches past its right edge, which at the edge of
        /// the screen cannot be seen, and never falls short of it, which
        /// would show what is behind: a window that shrinks is moved first,
        /// one that grows is resized first.
        func settleTrailing(_ index: Int) -> Bool {
            let window = trailing[index]
            let outerEdge = target.trailing[index].maxX
            let width = max(1, outerEdge - (line + gap))
            var frame = current.trailing[index]
            func readBack() -> Bool {
                guard let read = window.frame else { return false }
                frame = read
                return true
            }
            func move(toWidth width: CGFloat) {
                window.setPosition(CGPoint(x: outerEdge - width, y: frame.minY))
            }
            func resize() {
                window.setSize(CGSize(width: width, height: frame.height))
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
            if abs(frame.maxX - outerEdge) > tolerance {
                move(toWidth: frame.width)
                guard readBack() else { return false }
            }
            current.trailing[index] = frame
            return true
        }

        /// Where one side's windows let the line be, now that they have
        /// answered. A window reaching across the line would not shrink that
        /// far, and the line goes to it. Failing that, a window stopping
        /// short of the line would not grow that far, and the line goes to
        /// it, so the other side can close the space.
        func lineAgreed(byLeadingSide leadingSide: Bool) -> CGFloat {
            let edges = leadingSide ? current.leading.map { $0.maxX } : current.trailing.map { $0.minX - gap }
            guard let lowest = edges.min(), let highest = edges.max() else { return line }
            let across = leadingSide ? highest : lowest
            let short = leadingSide ? lowest : highest
            if abs(across - line) > tolerance, (across > line) == leadingSide { return across }
            if abs(short - line) > tolerance { return short }
            return line
        }

        let leadingGivesWay = line <= current.leadingEdge
        let sides = leadingGivesWay == cautious ? [true, false] : [false, true]
        for _ in 0..<3 {
            var revised = false
            for leadingSide in sides {
                for index in (leadingSide ? leading : trailing).indices {
                    guard leadingSide ? settleLeading(index) : settleTrailing(index) else { return unreadable }
                }
                let agreed = lineAgreed(byLeadingSide: leadingSide)
                if abs(agreed - line) > tolerance {
                    line = agreed
                    revised = true
                }
            }
            if !revised { break }
        }

        // Windows on both sides that chose their own width leave space over.
        // It goes to the far right, not between them: a position is never
        // refused, so a window on the right can always be slid up to the
        // left side.
        let reach = current.leadingEdge
        for index in trailing.indices where current.trailing[index].minX - (reach + gap) > tolerance {
            trailing[index].setPosition(CGPoint(x: reach + gap, y: current.trailing[index].minY))
            guard let moved = trailing[index].frame else { return unreadable }
            current.trailing[index] = moved
        }
        return Outcome(requested: target, final: current)
    }

    private static func read(_ leading: [SnapDividerWindow], _ trailing: [SnapDividerWindow]) -> SnapDividerGeometry.Frames? {
        let leadingFrames = leading.compactMap { $0.frame }
        let trailingFrames = trailing.compactMap { $0.frame }
        guard leadingFrames.count == leading.count, trailingFrames.count == trailing.count else { return nil }
        return SnapDividerGeometry.Frames(leading: leadingFrames, trailing: trailingFrames)
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

    private let leading: [SnapDividerWindow]
    private let trailing: [SnapDividerWindow]
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
    init(leading: [SnapDividerWindow], trailing: [SnapDividerWindow], gap: CGFloat,
         work: @escaping (@escaping () -> Void) -> Void,
         reply: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         begin: @escaping () -> () -> Void = { {} }) {
        self.leading = leading
        self.trailing = trailing
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
                let outcome = SnapDividerResize.apply(target, gap: gap, leading: leading, trailing: trailing,
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
