/// SnapDividerPanel.swift

import Cocoa

/// The handle shown on the seam between two side-by-side windows: a short
/// pill, centred on the seam. It takes the mouse but never the keyboard, and
/// never activates Rectangle, so the app being worked in keeps its focus.
final class SnapDividerPanel: NSPanel {

    /// How wide the pill is drawn, across the seam.
    static let pillThickness: CGFloat = 6
    /// How much of the visible seam the pill covers.
    static let pillLengthFraction: CGFloat = 1.0 / 3.0
    /// The pill is never shorter than this, unless the seam is.
    static let pillMinimumLength: CGFloat = 48
    /// Invisible margin on either side of the pill that also takes the mouse,
    /// so the pill is easier to hit than it is wide.
    static let hitPadding: CGFloat = 4

    static let pillFillColor = NSColor(white: 0.1, alpha: 0.7)
    static let pillBorderColor = NSColor(white: 1, alpha: 0.75)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = "Rectangle"
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        // Rectangle is never the active app, so a panel that hid on
        // deactivation would never be seen.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = SnapDividerHandleView()
    }

    /// The window list's id for this panel, so seam detection can look past
    /// it. The panel takes mouse events, so it cannot be recognised by
    /// `ignoresMouseEvents` the way the preview windows are.
    var windowID: CGWindowID? {
        windowNumber > 0 ? CGWindowID(exactly: windowNumber) : nil
    }

    /// Shows the handle with its pill at `pillFrame` (AppKit coordinates).
    func show(pillFrame: CGRect) {
        setFrame(pillFrame.insetBy(dx: -Self.hitPadding, dy: 0), display: true)
        orderFrontRegardless()
        if frame.contains(NSEvent.mouseLocation) {
            SnapDividerHandleView.resizeCursor.set()
        }
    }

    func hide() {
        guard isVisible else { return }
        // No exit event arrives for a window that goes away under the cursor.
        if frame.contains(NSEvent.mouseLocation) {
            NSCursor.arrow.set()
        }
        orderOut(nil)
    }
}

private final class SnapDividerHandleView: NSView {

    static var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    private var trackingArea: NSTrackingArea?

    // Cursor rectangles only work while the app is active, which Rectangle
    // never is. A tracking area that is always active reports the cursor
    // whatever app is in front.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited,
                                            .mouseMoved, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    // The app underneath can put its own cursor back at any time, so the
    // resize cursor is asserted again on every move.
    override func mouseMoved(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Taken so a click on the handle does not fall through to the windows
    // underneath.
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let border: CGFloat = 1
        let pill = bounds.insetBy(dx: SnapDividerPanel.hitPadding + border / 2, dy: border / 2)
        guard pill.width > 0, pill.height > 0 else { return }
        let radius = min(pill.width, pill.height) / 2
        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        SnapDividerPanel.pillFillColor.setFill()
        path.fill()
        SnapDividerPanel.pillBorderColor.setStroke()
        path.lineWidth = border
        path.stroke()
    }
}
