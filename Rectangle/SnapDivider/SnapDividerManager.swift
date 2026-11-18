/// SnapDividerManager.swift

import Cocoa

/// Shows a handle on the seam between windows that sit side by side, or one
/// above the other, when the cursor rests on it, and moves the seam when the
/// handle is dragged: the windows on one side grow as those on the other
/// shrink. Does nothing unless the `snapDivider` preference is on.
class SnapDividerManager {
    typealias Arrangement = SnapDividerGeometry.Arrangement

    private static let tickInterval: TimeInterval = 0.1
    private static let dwellInterval: TimeInterval = 0.15
    private static let moveTolerance: CGFloat = 2
    private static let axTimeout: Float = 0.25
    /// How far outside the gap the cursor still counts as on the seam.
    private static let hoverSlop: CGFloat = 4
    /// How far outside the gap the cursor may wander once the handle is
    /// showing. Wider than `hoverSlop`, so the handle does not flicker at the
    /// edge of the zone that summoned it.
    private static let staySlop: CGFloat = 12
    /// A window in front that comes this close to the gap covers the seam.
    /// Never less than half the handle's thickness, so the handle cannot land
    /// on such a window however the pill is tuned.
    private static var coverMargin: CGFloat {
        max(8, SnapDividerPanel.pillThickness / 2 + SnapDividerPanel.hitPadding)
    }
    private static let minimumSpan: CGFloat = 100
    /// How long an app gets to answer while its window is being resized.
    /// Longer than for a question: a slow answer here is a window still
    /// laying itself out, and what it did has to be read back afterwards.
    private static let resizeTimeout: Float = 1

    /// How far from exact two facing edges may be, beyond the configured gap.
    /// Wide enough for a terminal that stopped a character cell short, and a
    /// cell is about twice as tall as it is wide.
    private static func edgeTolerance(for arrangement: Arrangement) -> CGFloat {
        arrangement == .sideBySide ? 8 : 20
    }

    /// The smallest a window is dragged, across the seam, when its app
    /// reports no minimum size, which most do not. An app with a larger
    /// minimum than this simply refuses, and the seam settles where it allows.
    private static func fallbackMinimum(for arrangement: Arrangement) -> CGFloat {
        arrangement == .sideBySide ? 150 : 100
    }

    /// A seam and the windows that form it.
    struct Match {
        let arrangement: Arrangement
        /// The windows to the left of the seam, or above it, in order along
        /// it. Usually one. There are more where several line up along one
        /// side, such as two right quarters facing a left half.
        let leading: [WindowInfo]
        /// The windows to the right of the seam, or below it.
        let trailing: [WindowInfo]
        /// The seam, in the side-by-side geometry of `SnapDividerGeometry`.
        let seam: SnapDividerGeometry.Seam
        /// The stretch of the seam around the cursor that no other window
        /// covers.
        let clearSpan: ClosedRange<CGFloat>

        func isSame(as other: Match) -> Bool {
            arrangement == other.arrangement
                && leading.map { $0.id } == other.leading.map { $0.id }
                && trailing.map { $0.id } == other.trailing.map { $0.id }
                && seam == other.seam && clearSpan == other.clearSpan
        }
    }

    /// One of the windows on a seam, once its app has been asked about it.
    struct ResolvedWindow {
        let info: WindowInfo
        let element: AccessibilityElement
        let minimumSize: CGSize?
    }

    private struct Refusal: Error {
        let reason: String
    }

    /// The handle on screen and what it was shown for. The frames and points
    /// are in the side-by-side geometry of `SnapDividerGeometry`, except for
    /// the screen's.
    private struct Shown {
        let match: Match
        let leading: [ResolvedWindow]
        let trailing: [ResolvedWindow]
        /// The screen the seam is on, in the window list's coordinates.
        let screenFrame: CGRect
        let pillFrame: CGRect
        /// The point on the seam level with where the cursor found it,
        /// where the seam is looked up again to notice the windows moving.
        /// Not the centre of the handle: with several windows along one side
        /// that can fall in the space between two of them, where there is no
        /// window to find.
        let anchor: CGPoint
        /// Where the cursor may be without the handle going away.
        let stayZone: CGRect

        var arrangement: Arrangement { match.arrangement }
        var windows: [ResolvedWindow] { leading + trailing }
    }

    /// The handle being dragged.
    private struct Drag {
        /// Where the windows were when the mouse went down.
        let start: SnapDividerGeometry.Frames
        /// The gap the moved seam will leave between the two sides.
        let gap: CGFloat
        let minimumLeadingWidths: [CGFloat]
        let minimumTrailingWidths: [CGFloat]
        /// Where the handle now wants the windows.
        var target: SnapDividerGeometry.Frames
        /// Applies `target` to the windows as it changes.
        let session: SnapDividerResizeSession
        /// Whether the pointer has left the spot where the mouse went down.
        var hasMoved = false
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
    /// Set from the mouse coming up until the windows have caught up with
    /// where the handle was dropped.
    private var isApplying = false
    /// Windows are written here, one resize at a time, so a slow app holds
    /// up neither the handle nor anything else Rectangle is doing.
    private let resizeQueue = DispatchQueue(label: "com.knollsoft.Rectangle.snap-divider", qos: .userInteractive)

    init() {
        for name in [Notification.Name.snapDividerChanged, .configImported] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.toggleListening()
            }
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
        // While the windows catch up after a drag the handle is left alone;
        // it is put on the new seam once they have answered.
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
        // The seam has to be on the cursor's own display: `match` looks no
        // further than `screenFrame`.
        guard NSEvent.pressedMouseButtons == 0,
              !ApplicationToggle.shortcutsDisabled,
              let screen = (NSScreen.screens.first { NSPointInRect(location, $0.frame) })
        else { return }
        let screenFrame = screen.frame.screenFlipped
        let point = location.screenFlipped
        // Where four windows meet at a corner, the upright seam wins.
        guard let match = currentMatch(at: point, in: screenFrame, arrangement: .sideBySide)
                ?? currentMatch(at: point, in: screenFrame, arrangement: .stacked),
              // The window list keeps reporting ordinary frames while Mission
              // Control shows the windows somewhere else entirely.
              !MissionControl.isActive
        else { return }

        resolve(match) { [weak self] leading, trailing in
            self?.show(match, foundAt: point, leading: leading, trailing: trailing, in: screenFrame)
        }
    }

    private func currentMatch(at point: CGPoint, in screenFrame: CGRect, arrangement: Arrangement,
                              forceRefresh: Bool = false) -> Match? {
        Self.match(at: point, in: screenFrame,
                   windows: WindowUtil.getWindowList(forceRefresh: forceRefresh),
                   configuredGap: Defaults.gapSize.cgFloat,
                   arrangement: arrangement,
                   ignoring: Set([panel?.windowID].compactMap { $0 }))
    }

    /// Asks the apps about their windows, off the main thread, and calls
    /// `resolved` on the main thread if all of them can be resized and none
    /// is full screen - unless the cursor has moved on in the meantime. The
    /// window list cannot answer either question, so this is only asked once
    /// a seam has been found.
    private func resolve(_ match: Match, resolved: @escaping ([ResolvedWindow], [ResolvedWindow]) -> Void) {
        let requestGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { (try match.leading.map { try Self.resolve($0).get() },
                                   try match.trailing.map { try Self.resolve($0).get() }) }
            DispatchQueue.main.async {
                guard let self,
                      self.generation == requestGeneration,
                      self.timer != nil
                else { return }
                switch result {
                case let .success((leading, trailing)):
                    resolved(leading, trailing)
                case let .failure(error):
                    let reason = (error as? Refusal)?.reason ?? "\(error)"
                    Logger.log("Snap divider: no handle at \(Self.describe(match.seam.position, match.arrangement)), \(reason)")
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

    /// `point` is where the seam was found, in the window list's coordinates.
    private func show(_ match: Match, foundAt point: CGPoint,
                      leading: [ResolvedWindow], trailing: [ResolvedWindow], in screenFrame: CGRect) {
        let seam = match.seam
        let pillFrame = SnapDividerGeometry.handleFrame(on: seam, within: match.clearSpan,
                                                        thickness: SnapDividerPanel.pillThickness,
                                                        lengthFraction: SnapDividerPanel.pillLengthFraction,
                                                        minimumLength: SnapDividerPanel.pillMinimumLength)
        let reach = seam.gap / 2 + Self.staySlop
        shown = Shown(match: match,
                      leading: leading,
                      trailing: trailing,
                      screenFrame: screenFrame,
                      pillFrame: pillFrame,
                      anchor: CGPoint(x: seam.position, y: match.arrangement.canonical(point).y),
                      stayZone: CGRect(x: seam.position - reach,
                                       y: match.clearSpan.lowerBound,
                                       width: reach * 2,
                                       height: match.clearSpan.upperBound - match.clearSpan.lowerBound))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.show(pillFrame: match.arrangement.canonical(pillFrame).screenFlipped, arrangement: match.arrangement)
        Logger.log("Snap divider: handle at \(Self.describe(seam.position, match.arrangement)), gap \(seam.gap), between \(Self.describe(match.leading)) and \(Self.describe(match.trailing))")
    }

    private static func describe(_ position: CGFloat, _ arrangement: Arrangement) -> String {
        "\(arrangement == .sideBySide ? "x" : "y")=\(position)"
    }

    private static func describe(_ windows: [WindowInfo]) -> String {
        windows.map { "window \($0.id) (\($0.processName ?? "?"))" }.joined(separator: " + ")
    }

    /// Takes the handle away once the cursor has left the seam, a button has
    /// gone down somewhere else, or the windows are no longer where they
    /// were.
    private func checkShown(_ shown: Shown, cursor location: CGPoint) {
        panel?.updateCursor()
        let arrangement = shown.arrangement
        let onHandle = panel?.frame.contains(location) == true
        guard panel?.isVisible == true,
              !ApplicationToggle.shortcutsDisabled,
              NSEvent.pressedMouseButtons == 0 || onHandle,
              onHandle || shown.stayZone.contains(arrangement.canonical(location.screenFlipped))
        else {
            dismiss()
            return
        }

        if let match = currentMatch(at: arrangement.canonical(shown.anchor), in: shown.screenFrame,
                                    arrangement: arrangement),
           match.isSame(as: shown.match) {
            return
        }
        dismiss()
        // If the windows still meet, the handle comes back on the seam's new
        // position after the usual dwell.
        lookAgain()
    }

    private func dismiss() {
        // Invalidate any lookup in flight so a stale answer cannot bring the
        // handle back after a dismissal.
        generation += 1
        drag?.session.cancel()
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
        let arrangement = shown.arrangement
        let start = SnapDividerGeometry.Frames(leading: shown.leading.map { arrangement.canonical($0.info.frame) },
                                               trailing: shown.trailing.map { arrangement.canonical($0.info.frame) })
        let gap = SnapDividerGeometry.intendedGap(distance: start.trailingEdge - start.leadingEdge,
                                                  configuredGap: Defaults.gapSize.cgFloat,
                                                  tolerance: Self.edgeTolerance(for: arrangement))
        drag = Drag(start: start,
                    gap: gap,
                    minimumLeadingWidths: shown.leading.map { Self.minimumWidth(of: $0, arrangement) },
                    minimumTrailingWidths: shown.trailing.map { Self.minimumWidth(of: $0, arrangement) },
                    target: start,
                    session: makeSession(for: shown, gap: gap))
        return true
    }

    /// The smallest the divider makes a window, across the seam: what its
    /// app reports, or the fallback when it reports nothing. Never more than
    /// the window measures now, so a window already smaller is not made to
    /// grow.
    private static func minimumWidth(of window: ResolvedWindow, _ arrangement: Arrangement) -> CGFloat {
        let reported = arrangement.canonical(window.minimumSize ?? .zero).width
        return min(arrangement.canonical(window.info.frame).width,
                   max(reported, fallbackMinimum(for: arrangement)))
    }

    /// What resizes the windows during a drag: off the main thread, one
    /// position at a time, and only ever the latest.
    private func makeSession(for shown: Shown, gap: CGFloat) -> SnapDividerResizeSession {
        let windows = shown.windows
        let stacked = shown.arrangement == .stacked
        func writable(_ window: ResolvedWindow) -> SnapDividerWindow {
            let window = SnapDividerAXWindow(element: window.element.axElement)
            return stacked ? SnapDividerTransposedWindow(window: window) : window
        }
        let enhancedUI = Defaults.enhancedUI.value
        let assistiveTechnologyEnabled = NSWorkspace.shared.isVoiceOverEnabled
            || NSWorkspace.shared.isSwitchControlEnabled
        let queue = resizeQueue
        return SnapDividerResizeSession(
            leading: shown.leading.map(writable),
            trailing: shown.trailing.map(writable),
            gap: gap,
            work: { queue.async(execute: $0) },
            begin: {
                // The same care `AccessibilityElement.setFrame` takes: an app
                // with enhanced accessibility on animates a resize unless it
                // is turned off around it. Here that is once around the whole
                // drag, not once for every position.
                let restoreEnhancedUI = windows.map { window -> () -> Void in
                    window.element.setMessagingTimeout(Self.resizeTimeout)
                    return enhancedUI.beginWindowAdjustment(
                        bundleIdentifier: window.element.bundleIdentifier,
                        builtInAssistiveTechnologyEnabled: assistiveTechnologyEnabled,
                        readEnhancedUI: { window.element.enhancedUserInterface },
                        writeEnhancedUI: { window.element.enhancedUserInterface = $0 })
                }
                return {
                    for (window, restore) in zip(windows, restoreEnhancedUI) {
                        restore()
                        window.element.setMessagingTimeout(Self.axTimeout)
                    }
                }
            })
    }

    /// The handle follows the pointer as far as the windows' minimum sizes
    /// let the seam go, and the windows follow the handle.
    private func moveDrag(by distance: CGFloat) {
        guard var drag, let shown else { return }
        let target = SnapDividerGeometry.resized(drag.start, gap: drag.gap,
                                                 minimumLeadingWidths: drag.minimumLeadingWidths,
                                                 minimumTrailingWidths: drag.minimumTrailingWidths,
                                                 seamAt: shown.match.seam.position + distance)
        movePill(of: shown, toSeamAt: target.seamPosition)

        // A press that goes nowhere is not a request to move anything, even
        // where the gap between the windows could be tidied up.
        if abs(distance) >= 1 {
            drag.hasMoved = true
        }
        if drag.hasMoved, target != drag.target {
            drag.target = target
            drag.session.request(target)
        }
        self.drag = drag
    }

    private func movePill(of shown: Shown, toSeamAt position: CGFloat) {
        var pillFrame = shown.pillFrame
        pillFrame.origin.x = (position - SnapDividerPanel.pillThickness / 2).rounded()
        panel?.movePill(to: shown.arrangement.canonical(pillFrame).screenFlipped)
    }

    private func endDrag(by distance: CGFloat) {
        moveDrag(by: distance)
        guard let drag, let shown else { return }
        self.drag = nil
        guard drag.hasMoved else {
            drag.session.cancel()
            movePill(of: shown, toSeamAt: shown.match.seam.position)
            return
        }
        // The windows may still be a position or two behind the handle.
        isApplying = true
        drag.session.finish { [weak self] outcome in
            self?.finishApplying(outcome, for: shown)
        }
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

    /// The windows have caught up with where the handle was dropped.
    /// `outcome` is nil if the drag never asked them to move.
    private func finishApplying(_ outcome: SnapDividerResize.Outcome?, for shown: Shown) {
        isApplying = false
        let arrangement = shown.arrangement
        guard let outcome else {
            if self.shown != nil {
                movePill(of: shown, toSeamAt: shown.match.seam.position)
            }
            return
        }

        // The windows are no longer where a Rectangle action put them, just
        // as after resizing one of them by its own edge.
        for window in shown.windows {
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: window.info.id)
        }

        if let final = outcome.final {
            let frames = zip(shown.windows, final.leading + final.trailing)
                .map { "window \($0.info.id) is now \(arrangement.canonical($1))" }
                .joined(separator: ", ")
            var message = "Snap divider: seam moved to \(Self.describe(final.seamPosition, arrangement)); \(frames)"
            if outcome.wasRevised {
                message += " (\(Self.describe(outcome.requested.seamPosition, arrangement)) was asked for, but a window chose its own size)"
            }
            Logger.log(message)
        } else {
            Logger.log("Snap divider: asked for the seam at \(Self.describe(outcome.requested.seamPosition, arrangement)), but the windows could not be read back")
        }

        // Unless the handle was dismissed in the meantime, it goes on the
        // seam where the windows ended up, which is not always where it was
        // dropped.
        guard self.shown != nil else { return }
        let position = outcome.final?.seamPosition ?? outcome.requested.seamPosition
        let anchor = arrangement.canonical(CGPoint(x: position, y: shown.anchor.y))
        if let match = currentMatch(at: anchor, in: shown.screenFrame, arrangement: arrangement, forceRefresh: true),
           let leading = Self.carriedOver(shown.leading, to: match.leading),
           let trailing = Self.carriedOver(shown.trailing, to: match.trailing) {
            show(match, foundAt: anchor, leading: leading, trailing: trailing, in: shown.screenFrame)
        } else {
            // The window list can be a moment behind the windows. The usual
            // dwell finds the seam once it has caught up.
            dismiss()
            lookAgain()
        }
    }

    /// The windows already asked about, with where the window list has them
    /// now - or nil if the list no longer has the same windows there.
    private static func carriedOver(_ windows: [ResolvedWindow], to infos: [WindowInfo]) -> [ResolvedWindow]? {
        guard windows.map({ $0.info.id }) == infos.map({ $0.id }) else { return nil }
        return zip(windows, infos).map {
            ResolvedWindow(info: $1, element: $0.element, minimumSize: $0.minimumSize)
        }
    }

    // MARK: Finding a seam

    /// The seam under `point`, if the frontmost windows on either side of it
    /// are two different windows that meet there. Only the frontmost windows
    /// are considered, so an edge that is covered never matches.
    ///
    /// For `.sideBySide` the two sides are left and right of `point`, and for
    /// `.stacked` above and below it. Where one side goes on further along
    /// the seam than the other, the windows that carry the other side on are
    /// part of the seam too.
    ///
    /// `windows` is front to back, and nothing off `screenFrame` is looked
    /// at. Everything is in the window list's coordinates (top-left origin).
    static func match(at point: CGPoint, in screenFrame: CGRect, windows: [WindowInfo],
                      configuredGap: CGFloat, arrangement: Arrangement = .sideBySide,
                      ignoring ignoredWindows: Set<CGWindowID> = []) -> Match? {
        // From here on everything is side by side: for stacked windows x and
        // y change places, and "left" and "right" stand for above and below.
        let original = windows
        let windows = arrangement == .sideBySide ? original : original.map {
            WindowInfo(id: $0.id, level: $0.level, frame: arrangement.canonical($0.frame),
                       pid: $0.pid, processName: $0.processName, alpha: $0.alpha)
        }
        let point = arrangement.canonical(point)
        let screenFrame = arrangement.canonical(screenFrame)

        let tolerance = edgeTolerance(for: arrangement)
        let maxGap = max(0, configuredGap) + tolerance
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
              let pairSeam = SnapDividerGeometry.seam(left: left.frame, right: right.frame,
                                                      maxGap: maxGap, maxOverlap: tolerance,
                                                      minimumSpan: minimumSpan)
        else { return nil }

        // One side may go on along the seam where the other stops: a left
        // half has a right quarter beside its upper part and another beside
        // its lower. Each side is followed along the seam, a window at a
        // time, as far as the other reaches.
        var leading = [leftIndex]
        var trailing = [rightIndex]
        // Windows following one another along the seam are side by side when
        // the seam's own are stacked, and stacked when they are side by side.
        let toleranceAlong = edgeTolerance(for: arrangement == .sideBySide ? .stacked : .sideBySide)
        let maxGapAlong = max(0, configuredGap) + toleranceAlong
        func cover(_ indices: [Int]) -> ClosedRange<CGFloat> {
            let frames = indices.map { windows[$0].frame }
            return (frames.map { $0.minY }.min() ?? 0)...(frames.map { $0.maxY }.max() ?? 0)
        }
        func extend(leadingSide: Bool, towardsStart: Bool) -> Bool {
            let own = cover(leadingSide ? leading : trailing)
            let other = cover(leadingSide ? trailing : leading)
            guard towardsStart ? other.lowerBound < own.lowerBound - toleranceAlong
                               : other.upperBound > own.upperBound + toleranceAlong
            else { return false }
            let step = maxGapAlong + hoverSlop + 1
            let probe = CGPoint(x: pairSeam.position + (leadingSide ? -reach : reach),
                                y: towardsStart ? own.lowerBound - step : own.upperBound + step)
            guard screenFrame.contains(probe),
                  let index = frontmostIndex(at: probe),
                  !leading.contains(index), !trailing.contains(index)
            else { return false }
            let window = windows[index]
            // It belongs if its edge is on the same line as the first one's,
            // and it follows straight on from the windows found so far.
            let offLine = leadingSide ? window.frame.maxX - left.frame.maxX : window.frame.minX - right.frame.minX
            let distanceAlong = towardsStart ? own.lowerBound - window.frame.maxY : window.frame.minY - own.upperBound
            guard window.level == kCGNormalWindowLevel,
                  window.frame.isValidWindowFrame,
                  abs(offLine) <= tolerance,
                  distanceAlong <= maxGapAlong, -distanceAlong <= toleranceAlong
            else { return false }
            if leadingSide { leading.append(index) } else { trailing.append(index) }
            return true
        }
        var extended = true
        while extended {
            extended = false
            for leadingSide in [true, false] {
                for towardsStart in [true, false] {
                    while extend(leadingSide: leadingSide, towardsStart: towardsStart) {
                        extended = true
                    }
                }
            }
        }
        // In order along the seam, so the same windows always come out the
        // same way round whichever of them the cursor was beside.
        leading.sort { windows[$0].frame.minY < windows[$1].frame.minY }
        trailing.sort { windows[$0].frame.minY < windows[$1].frame.minY }

        // The seam of all of them: between the window reaching furthest on
        // one side and the one beginning soonest on the other, along the
        // stretch that has windows on both sides.
        let leadingEdge = leading.map { windows[$0].frame.maxX }.max() ?? left.frame.maxX
        let trailingEdge = trailing.map { windows[$0].frame.minX }.min() ?? right.frame.minX
        let leadingCover = cover(leading)
        let trailingCover = cover(trailing)
        let spanStart = max(leadingCover.lowerBound, trailingCover.lowerBound)
        let spanEnd = min(leadingCover.upperBound, trailingCover.upperBound)
        guard spanEnd - spanStart >= minimumSpan else { return nil }
        let seam = SnapDividerGeometry.Seam(position: (leadingEdge + trailingEdge) / 2,
                                            gap: max(0, trailingEdge - leadingEdge),
                                            span: spanStart...spanEnd)
        // The cursor was found beside two of the windows, and is on the seam
        // if it is on theirs or on the seam of them all. The two differ only
        // where windows along one side are not quite in line.
        guard pairSeam.isNear(point, slop: hoverSlop) || seam.isNear(point, slop: hoverSlop) else { return nil }

        // Something narrower than the distance between the probes can still
        // cover the seam, here or further along it. Only windows in front of
        // one of the seam's own can: whatever shows through a gap from behind
        // all of them is fine.
        let members = leading + trailing
        let coverReach = seam.gap / 2 + coverMargin
        let covered = windows[..<(members.max() ?? 0)].enumerated().compactMap { index, info -> ClosedRange<CGFloat>? in
            let frame = info.frame
            guard !members.contains(index),
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

        return Match(arrangement: arrangement,
                     leading: leading.map { original[$0] },
                     trailing: trailing.map { original[$0] },
                     seam: seam,
                     clearSpan: clearSpan)
    }
}
