/// SnapDividerManager.swift

import Cocoa

/// Shows a handle on the seam between two side-by-side windows when the
/// cursor rests on it, and moves the seam when the handle is dragged: one
/// window grows as the other shrinks. Does nothing unless the hidden
/// `snapDivider` preference is on.
class SnapDividerManager {

    private static let tickInterval: TimeInterval = 0.1
    private static let dwellInterval: TimeInterval = 0.15
    private static let moveTolerance: CGFloat = 2
    private static let axTimeout: Float = 0.25
    /// How far from exact two facing edges may be, beyond the configured gap.
    /// Wide enough for a terminal that stopped a character cell short.
    private static let edgeTolerance: CGFloat = 8
    /// How far outside the gap the cursor still counts as on the seam.
    private static let hoverSlop: CGFloat = 4
    /// How far outside the gap the cursor may wander once the handle is
    /// showing. Wider than `hoverSlop`, so the handle does not flicker at the
    /// edge of the zone that summoned it.
    private static let staySlop: CGFloat = 12
    /// A window in front that comes this close to the gap covers the seam.
    /// Never less than half the handle's width, so the handle cannot land on
    /// such a window however the pill is tuned.
    private static var coverMargin: CGFloat {
        max(8, SnapDividerPanel.pillThickness / 2 + SnapDividerPanel.hitPadding)
    }
    private static let minimumSpan: CGFloat = 100
    /// How long an app gets to answer while its window is being resized.
    /// Longer than for a question: a slow answer here is a window still
    /// laying itself out, and what it did has to be read back afterwards.
    private static let resizeTimeout: Float = 1
    /// The narrowest a window is dragged when its app reports no minimum
    /// size, which most do not. An app with a larger minimum than this simply
    /// refuses, and the seam settles where it allows.
    private static let fallbackMinimumWidth: CGFloat = 150

    /// A seam and the two windows that form it.
    struct Match {
        let left: WindowInfo
        let right: WindowInfo
        let seam: SnapDividerGeometry.Seam
        /// The stretch of the seam around the cursor that no other window
        /// covers.
        let clearSpan: ClosedRange<CGFloat>

        func isSame(as other: Match) -> Bool {
            left.id == other.left.id && right.id == other.right.id
                && seam == other.seam && clearSpan == other.clearSpan
        }
    }

    /// One of the two windows, once its app has been asked about it.
    struct ResolvedWindow {
        let info: WindowInfo
        let element: AccessibilityElement
        let minimumSize: CGSize?
    }

    private struct Refusal: Error {
        let reason: String
    }

    /// The handle on screen and what it was shown for. Everything is in the
    /// window list's coordinates (top-left origin).
    private struct Shown {
        let match: Match
        let left: ResolvedWindow
        let right: ResolvedWindow
        let screenFrame: CGRect
        let pillFrame: CGRect
        /// The centre of the handle, where the seam is looked up again to
        /// notice the windows moving.
        let anchor: CGPoint
        /// Where the cursor may be without the handle going away.
        let stayZone: CGRect
    }

    /// The handle being dragged.
    private struct Drag {
        /// Where the two windows were when the mouse went down.
        let start: SnapDividerGeometry.Frames
        /// The gap the moved seam will leave between them.
        let gap: CGFloat
        let minimumLeftWidth: CGFloat
        let minimumRightWidth: CGFloat
        /// Where the two windows go if the mouse comes up now.
        var target: SnapDividerGeometry.Frames
        var ticksWithoutButton = 0
    }

    private var timer: Timer?
    private var lastMouseLocation = CGPoint.zero
    private var lastMoveTime: TimeInterval = 0
    private var dwellFired = false
    private var generation = 0

    private var panel: SnapDividerPanel?
    private var shown: Shown?
    private var drag: Drag?
    /// Set from the mouse coming up until the windows have been resized.
    private var isApplying = false
    /// Windows are written here, one resize at a time, so a slow app holds
    /// up neither the handle nor anything else Rectangle is doing.
    private let resizeQueue = DispatchQueue(label: "com.knollsoft.Rectangle.snap-divider", qos: .userInteractive)

    init() {
        NotificationCenter.default.addObserver(
            forName: .configImported,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.toggleListening()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
        // An action is about to move windows, and the ones that act on every
        // window on screen would take the handle for one of them.
        NotificationCenter.default.addObserver(
            forName: .windowActionWillExecute,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
        toggleListening()
    }

    private func toggleListening() {
        if Defaults.snapDivider.enabled {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0.05
            // .common keeps the handle following the cursor during menu and
            // event tracking, where default-mode timers pause.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            dismiss()
        }
    }

    private func tick() {
        // While the windows are being resized the handle is left alone; it is
        // put on the new seam once they have answered.
        guard !isApplying else { return }
        if drag != nil {
            checkDrag()
            return
        }

        let location = NSEvent.mouseLocation
        if let shown {
            checkShown(shown, cursor: location)
        }

        if abs(location.x - lastMouseLocation.x) > Self.moveTolerance
            || abs(location.y - lastMouseLocation.y) > Self.moveTolerance {
            lastMouseLocation = location
            lastMoveTime = ProcessInfo.processInfo.systemUptime
            dwellFired = false
            // A lookup still in flight was for somewhere the cursor has left.
            generation += 1
            return
        }

        guard shown == nil, !dwellFired,
              ProcessInfo.processInfo.systemUptime - lastMoveTime >= Self.dwellInterval
        else { return }
        dwellFired = true

        // A held button means a drag or a selection is under way somewhere
        // else, and a disabled front app means Rectangle stays out of the way.
        guard NSEvent.pressedMouseButtons == 0,
              !ApplicationToggle.shortcutsDisabled,
              let screen = (NSScreen.screens.first { NSPointInRect(location, $0.frame) })
        else { return }
        let screenFrame = screen.frame.screenFlipped
        guard let match = currentMatch(at: location.screenFlipped, in: screenFrame),
              // The window list keeps reporting ordinary frames while Mission
              // Control shows the windows somewhere else entirely.
              !MissionControl.isActive
        else { return }

        resolve(match) { [weak self] left, right in
            self?.show(match, left: left, right: right, in: screenFrame)
        }
    }

    private func currentMatch(at point: CGPoint, in screenFrame: CGRect, forceRefresh: Bool = false) -> Match? {
        Self.match(at: point, in: screenFrame,
                   windows: WindowUtil.getWindowList(forceRefresh: forceRefresh),
                   configuredGap: Defaults.gapSize.cgFloat,
                   ignoring: Set([panel?.windowID].compactMap { $0 }))
    }

    /// Asks both apps about their window, off the main thread, and calls
    /// `resolved` on the main thread if both can be resized and neither is
    /// full screen - unless the cursor has moved on in the meantime. The
    /// window list cannot answer either question, so this is only asked once
    /// a seam has been found.
    private func resolve(_ match: Match, resolved: @escaping (ResolvedWindow, ResolvedWindow) -> Void) {
        let requestGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let left = Self.resolve(match.left)
            let right = Self.resolve(match.right)
            DispatchQueue.main.async {
                guard let self,
                      self.generation == requestGeneration,
                      self.timer != nil
                else { return }
                switch (left, right) {
                case let (.success(left), .success(right)):
                    resolved(left, right)
                case let (.failure(refusal), _), let (_, .failure(refusal)):
                    Logger.log("Snap divider: no handle at x=\(match.seam.position), \(refusal.reason)")
                }
            }
        }
    }

    /// Finds the window's accessibility element and what its app says about
    /// resizing it. Resolves the window by pid directly (no shared
    /// window-list cache off the main thread), with AX timeouts so an
    /// unresponsive app cannot hold the answer up for long.
    private static func resolve(_ info: WindowInfo) -> Result<ResolvedWindow, Refusal> {
        let name = "window \(info.id) (\(info.processName ?? "?"))"
        let appElement = AccessibilityElement(info.pid)
        appElement.setMessagingTimeout(axTimeout)
        let windowElement = appElement.windowElements?.first { element in
            // The cap is per accessibility object, so each window element has
            // to be capped before it is asked anything.
            element.setMessagingTimeout(axTimeout)
            return element.windowId == info.id
        }
        guard let windowElement else {
            return .failure(Refusal(reason: "\(name) was not found - it has closed, or its app did not answer in time"))
        }
        // An app that does not say is taken to allow it, as elsewhere.
        if windowElement.axElement.isValueSettable(.size) == false {
            return .failure(Refusal(reason: "\(name) is not resizable"))
        }
        if windowElement.isFullScreen == true {
            return .failure(Refusal(reason: "\(name) is full screen"))
        }
        // The seam was found in the window list, and the windows are resized
        // through accessibility. Where the two disagree about a window, in
        // mid-animation or because its app draws its own margins, moving it
        // by the one's numbers would put it somewhere else by the other's.
        let frame = windowElement.frame
        guard frame.isNear(info.frame) else {
            return .failure(Refusal(reason: "\(name) reports the frame \(frame), but is shown at \(info.frame)"))
        }
        return .success(ResolvedWindow(info: info, element: windowElement, minimumSize: windowElement.minimumSize))
    }

    private func show(_ match: Match, left: ResolvedWindow, right: ResolvedWindow, in screenFrame: CGRect) {
        let seam = match.seam
        let pillFrame = SnapDividerGeometry.handleFrame(on: seam, within: match.clearSpan,
                                                        thickness: SnapDividerPanel.pillThickness,
                                                        lengthFraction: SnapDividerPanel.pillLengthFraction,
                                                        minimumLength: SnapDividerPanel.pillMinimumLength)
        let reach = seam.gap / 2 + Self.staySlop
        shown = Shown(match: match,
                      left: left,
                      right: right,
                      screenFrame: screenFrame,
                      pillFrame: pillFrame,
                      anchor: CGPoint(x: seam.position, y: pillFrame.midY),
                      stayZone: CGRect(x: seam.position - reach,
                                       y: match.clearSpan.lowerBound,
                                       width: reach * 2,
                                       height: match.clearSpan.upperBound - match.clearSpan.lowerBound))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.show(pillFrame: pillFrame.screenFlipped)
        Logger.log("Snap divider: handle at x=\(seam.position), gap \(seam.gap), between window \(match.left.id) (\(match.left.processName ?? "?")) and window \(match.right.id) (\(match.right.processName ?? "?"))")
    }

    /// Takes the handle away once the cursor has left the seam, a button has
    /// gone down somewhere else, or the windows are no longer where they
    /// were.
    private func checkShown(_ shown: Shown, cursor location: CGPoint) {
        panel?.updateCursor()
        let onHandle = panel?.frame.contains(location) == true
        guard panel?.isVisible == true,
              !ApplicationToggle.shortcutsDisabled,
              NSEvent.pressedMouseButtons == 0 || onHandle,
              onHandle || shown.stayZone.contains(location.screenFlipped)
        else {
            dismiss()
            return
        }

        if let match = currentMatch(at: shown.anchor, in: shown.screenFrame),
           match.isSame(as: shown.match) {
            return
        }
        dismiss()
        // If the two still meet, the handle comes back on the seam's new
        // position after the usual dwell.
        lookAgain()
    }

    private func dismiss() {
        // Invalidate any lookup in flight so a stale answer cannot bring the
        // handle back after a dismissal.
        generation += 1
        drag = nil
        guard shown != nil else { return }
        shown = nil
        panel?.hide()
    }

    /// Looks again at once for a seam under a cursor that has not moved,
    /// which nothing else would do.
    private func lookAgain() {
        lastMoveTime = ProcessInfo.processInfo.systemUptime
        dwellFired = false
    }

    // MARK: Dragging

    private func makePanel() -> SnapDividerPanel {
        let panel = SnapDividerPanel()
        panel.dragShouldBegin = { [weak self] in self?.beginDrag() ?? false }
        panel.dragMoved = { [weak self] distance in self?.moveDrag(by: distance) }
        panel.dragEnded = { [weak self] distance in self?.endDrag(by: distance) }
        return panel
    }

    private func beginDrag() -> Bool {
        guard let shown, drag == nil, !isApplying else { return false }
        let start = SnapDividerGeometry.Frames(left: shown.left.info.frame, right: shown.right.info.frame)
        drag = Drag(start: start,
                    gap: SnapDividerGeometry.intendedGap(distance: start.right.minX - start.left.maxX,
                                                         configuredGap: Defaults.gapSize.cgFloat,
                                                         tolerance: Self.edgeTolerance),
                    minimumLeftWidth: Self.minimumWidth(of: shown.left),
                    minimumRightWidth: Self.minimumWidth(of: shown.right),
                    target: start)
        return true
    }

    /// The narrowest the divider makes a window: what its app reports, or the
    /// fallback when it reports nothing. Never more than the window's width
    /// now, so a window already narrower is not made to grow.
    private static func minimumWidth(of window: ResolvedWindow) -> CGFloat {
        min(window.info.frame.width, max(window.minimumSize?.width ?? 0, fallbackMinimumWidth))
    }

    /// The handle follows the pointer as far as the windows' minimum widths
    /// let the seam go. The windows themselves stay put until the mouse comes
    /// up.
    private func moveDrag(by distance: CGFloat) {
        guard var drag, let shown else { return }
        drag.target = SnapDividerGeometry.resized(drag.start, gap: drag.gap,
                                                  minimumLeftWidth: drag.minimumLeftWidth,
                                                  minimumRightWidth: drag.minimumRightWidth,
                                                  seamAt: shown.match.seam.position + distance)
        self.drag = drag
        panel?.movePill(toMinX: (drag.target.seamPosition - SnapDividerPanel.pillThickness / 2).rounded())
    }

    private func endDrag(by distance: CGFloat) {
        moveDrag(by: distance)
        guard let drag, let shown else { return }
        self.drag = nil
        // A press that went nowhere is not a request to move anything, even
        // where the gap between the two windows could be tidied up.
        guard abs(distance) >= 1, drag.target != drag.start else {
            panel?.movePill(toMinX: shown.pillFrame.minX)
            return
        }
        apply(drag, for: shown)
    }

    /// A drag ends with the mouse coming up on the handle. Should that event
    /// never arrive, the handle must not stay stuck to the pointer.
    private func checkDrag() {
        panel?.updateCursor()
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            drag?.ticksWithoutButton = 0
            return
        }
        // The button is up well before its event has been handled, so one
        // tick without it means nothing yet.
        drag?.ticksWithoutButton += 1
        if let drag, drag.ticksWithoutButton >= 5 {
            Logger.log("Snap divider: drag abandoned, the mouse came up without the handle being told")
            dismiss()
        }
    }

    /// Writes both frames once, off the main thread, then reads back what
    /// the windows did and corrects it if one of them refused its size.
    private func apply(_ drag: Drag, for shown: Shown) {
        isApplying = true
        let windows = [shown.left, shown.right]
        let enhancedUI = Defaults.enhancedUI.value
        let assistiveTechnologyEnabled = NSWorkspace.shared.isVoiceOverEnabled
            || NSWorkspace.shared.isSwitchControlEnabled
        resizeQueue.async { [weak self] in
            // The same care `AccessibilityElement.setFrame` takes: an app with
            // enhanced accessibility on animates a resize unless it is turned
            // off around it.
            let restoreEnhancedUI = windows.map { window -> () -> Void in
                window.element.setMessagingTimeout(Self.resizeTimeout)
                return enhancedUI.beginWindowAdjustment(
                    bundleIdentifier: window.element.bundleIdentifier,
                    builtInAssistiveTechnologyEnabled: assistiveTechnologyEnabled,
                    readEnhancedUI: { window.element.enhancedUserInterface },
                    writeEnhancedUI: { window.element.enhancedUserInterface = $0 })
            }
            let outcome = SnapDividerResize.apply(drag.target, gap: drag.gap,
                                                  left: SnapDividerAXWindow(element: shown.left.element.axElement),
                                                  right: SnapDividerAXWindow(element: shown.right.element.axElement))
            for (window, restore) in zip(windows, restoreEnhancedUI) {
                restore()
                window.element.setMessagingTimeout(Self.axTimeout)
            }
            DispatchQueue.main.async {
                self?.finishApplying(outcome, for: shown)
            }
        }
    }

    private func finishApplying(_ outcome: SnapDividerResize.Outcome, for shown: Shown) {
        isApplying = false
        // The windows are no longer where a Rectangle action put them, just
        // as after resizing one of them by its own edge.
        for window in [shown.left, shown.right] {
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: window.info.id)
        }

        if let final = outcome.final {
            var message = "Snap divider: seam moved to x=\(final.seamPosition); window \(shown.left.info.id) is now \(final.left), window \(shown.right.info.id) is now \(final.right)"
            if outcome.corrected != nil {
                message += " (x=\(outcome.requested.seamPosition) was asked for, but a window chose its own width)"
            }
            Logger.log(message)
        } else {
            Logger.log("Snap divider: asked for the seam at x=\(outcome.requested.seamPosition), but the windows could not be read back")
        }

        // Unless the handle was dismissed in the meantime, it goes on the
        // seam where the windows ended up, which is not always where it was
        // dropped.
        guard self.shown != nil else { return }
        let position = outcome.final?.seamPosition ?? outcome.requested.seamPosition
        if let match = currentMatch(at: CGPoint(x: position, y: shown.anchor.y), in: shown.screenFrame, forceRefresh: true),
           match.left.id == shown.left.info.id, match.right.id == shown.right.info.id {
            show(match,
                 left: ResolvedWindow(info: match.left, element: shown.left.element, minimumSize: shown.left.minimumSize),
                 right: ResolvedWindow(info: match.right, element: shown.right.element, minimumSize: shown.right.minimumSize),
                 in: shown.screenFrame)
        } else {
            // The window list can be a moment behind the windows. The usual
            // dwell finds the seam once it has caught up.
            dismiss()
            lookAgain()
        }
    }

    /// The seam under `point`, if the frontmost windows on either side of it
    /// are two different windows that meet there. Only the frontmost windows
    /// are considered, so an edge that is covered never matches.
    ///
    /// `windows` is front to back. Everything is in the window list's
    /// coordinates (top-left origin).
    static func match(at point: CGPoint, in screenFrame: CGRect, windows: [WindowInfo],
                      configuredGap: CGFloat,
                      ignoring ignoredWindows: Set<CGWindowID> = []) -> Match? {
        let maxGap = max(0, configuredGap) + edgeTolerance
        // Far enough that each probe lands inside a window even with the
        // cursor at the far side of the hover zone of the widest gap allowed.
        let reach = maxGap + hoverSlop + 1
        let leftProbe = CGPoint(x: point.x - reach, y: point.y)
        let rightProbe = CGPoint(x: point.x + reach, y: point.y)

        // Windows on neighbouring displays meet at the display boundary
        // without sharing an edge anyone could drag.
        guard screenFrame.contains(leftProbe), screenFrame.contains(rightProbe) else { return nil }

        func frontmostIndex(at location: CGPoint) -> Int? {
            guard let info = AccessibilityElement.windowInfoUnderCursor(at: location, windows: windows,
                                                                       ignoring: ignoredWindows)
            else { return nil }
            return windows.firstIndex { $0.id == info.id }
        }

        guard let leftIndex = frontmostIndex(at: leftProbe),
              let rightIndex = frontmostIndex(at: rightProbe),
              leftIndex != rightIndex
        else { return nil }
        let left = windows[leftIndex]
        let right = windows[rightIndex]

        guard left.level == kCGNormalWindowLevel, right.level == kCGNormalWindowLevel,
              let seam = SnapDividerGeometry.seam(left: left.frame, right: right.frame,
                                                  maxGap: maxGap, maxOverlap: edgeTolerance,
                                                  minimumSpan: minimumSpan),
              seam.isNear(point, slop: hoverSlop)
        else { return nil }

        // Something narrower than the distance between the probes can still
        // cover the seam, here or further along it. Only windows in front of
        // one of the pair can: whatever shows through a gap from behind both
        // is fine.
        let coverReach = seam.gap / 2 + coverMargin
        let covered = windows[..<max(leftIndex, rightIndex)].enumerated().compactMap { index, info -> ClosedRange<CGFloat>? in
            let frame = info.frame
            guard index != leftIndex, index != rightIndex,
                  frame.isValidWindowFrame,
                  frame.minX <= seam.position + coverReach, frame.maxX >= seam.position - coverReach,
                  // Asked of the window alone, this is whether it counts as
                  // a window that can be under the cursor at all.
                  AccessibilityElement.windowInfoUnderCursor(at: frame.centerPoint, windows: [info],
                                                             ignoring: ignoredWindows) != nil
            else { return nil }
            return frame.minY...frame.maxY
        }
        guard let clearSpan = SnapDividerGeometry.clearStretch(of: seam.span, around: point.y, blockedBy: covered),
              clearSpan.upperBound - clearSpan.lowerBound >= minimumSpan
        else { return nil }

        return Match(left: left, right: right, seam: seam, clearSpan: clearSpan)
    }
}
