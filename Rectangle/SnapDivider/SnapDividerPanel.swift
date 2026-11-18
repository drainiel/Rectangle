/// SnapDividerPanel.swift

import Cocoa

/// The handle shown on the seam between two side-by-side windows: a short
/// pill, centred on the seam. It takes the mouse but never the keyboard, and
/// never activates Rectangle, so the app being worked in keeps its focus.
final class SnapDividerPanel: NSPanel {

    /// How wide the pill is drawn, across the seam.
    static let pillThickness: CGFloat = 8
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
        // Left alone, a window lets the mouse through wherever it is
        // transparent, which would make the margin around the pill useless.
        // Setting this at all, even to false, turns that off.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]
        // The panel sets the cursor itself; AppKit's own management would
        // only get in the way.
        disableCursorRects()
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
        BackgroundCursor.setAllowed(true)
        updateCursor()
    }

    func hide() {
        guard isVisible else { return }
        // No exit event arrives for a window that goes away under the cursor.
        if pointerIsOnHandle {
            takeDownCursor()
        }
        pointerIsOnHandle = false
        BackgroundCursor.setAllowed(false)
        orderOut(nil)
    }

    // MARK: Cursor

    private static var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    private var pointerIsOnHandle = false

    /// Puts the resize cursor up while the pointer is on the handle and takes
    /// it down once it has left.
    ///
    /// Called for every mouse event on the handle, and from the manager's
    /// timer as well: the handle can appear under a pointer that is not
    /// moving, and the app in front goes on setting its own cursor whenever
    /// it likes.
    func updateCursor() {
        let onHandle = isVisible && frame.contains(NSEvent.mouseLocation)
        if onHandle {
            Self.resizeCursor.set()
        } else if pointerIsOnHandle {
            takeDownCursor()
        }
        pointerIsOnHandle = onHandle
    }

    /// Nothing else will take the resize cursor down: the app in front only
    /// resets a cursor it set itself. But where the pointer went, another app
    /// may already have put its own cursor up, and that one has to stay.
    private func takeDownCursor() {
        if let showing = NSCursor.currentSystem, !Self.resizeCursor.hasSameShape(as: showing) {
            return
        }
        NSCursor.arrow.set()
    }
}

/// Lets Rectangle change the cursor although it is never the active app.
///
/// The window server ignores `NSCursor.set()` from an app in the background,
/// and there is no public way round that. Its `SetsCursorInBackground`
/// connection property is the one switch for it, and it is private, so the
/// two functions are looked up by name: on a system where they are gone, the
/// cursor simply stays as it is.
private enum BackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef?) -> Int32

    private static let functions: (mainConnectionID: MainConnectionID,
                                   setConnectionProperty: SetConnectionProperty)? = {
        let anyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let mainConnectionID = dlsym(anyLoadedImage, "CGSMainConnectionID"),
              let setConnectionProperty = dlsym(anyLoadedImage, "CGSSetConnectionProperty")
        else {
            Logger.log("Snap divider: unable to change the cursor in the background on this system")
            return nil
        }
        return (unsafeBitCast(mainConnectionID, to: MainConnectionID.self),
                unsafeBitCast(setConnectionProperty, to: SetConnectionProperty.self))
    }()

    /// Only meant to be on while the handle is on screen, so nothing else
    /// Rectangle does can reach the cursor of the app in front.
    static func setAllowed(_ allowed: Bool) {
        guard let functions else { return }
        let connection = functions.mainConnectionID()
        _ = functions.setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString,
                                            allowed ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

private extension NSCursor {
    /// Whether two cursors are the same picture. Compared by proportions and
    /// not by size, since the pointer size setting scales every cursor.
    func hasSameShape(as other: NSCursor) -> Bool {
        let size = image.size
        let otherSize = other.image.size
        guard size.width > 0, size.height > 0, otherSize.width > 0, otherSize.height > 0 else { return false }
        let tolerance: CGFloat = 0.05
        return abs(size.width / size.height - otherSize.width / otherSize.height) < tolerance
            && abs(hotSpot.x / size.width - other.hotSpot.x / otherSize.width) < tolerance
            && abs(hotSpot.y / size.height - other.hotSpot.y / otherSize.height) < tolerance
    }
}

private final class SnapDividerHandleView: NSView {

    private var trackingArea: NSTrackingArea?

    private var panel: SnapDividerPanel? { window as? SnapDividerPanel }

    // Cursor rectangles only work while the app is active, which Rectangle
    // never is. A tracking area that is always active reports the pointer
    // whatever app is in front.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        panel?.updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        panel?.updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        panel?.updateCursor()
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
