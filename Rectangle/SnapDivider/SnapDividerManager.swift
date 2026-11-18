/// SnapDividerManager.swift

import Cocoa

/// Shows a handle on the seam between two side-by-side windows when the
/// cursor rests on it. Does nothing unless the hidden `snapDivider`
/// preference is on.
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

    /// The handle on screen and what it was shown for. Everything is in the
    /// window list's coordinates (top-left origin).
    private struct Shown {
        let match: Match
        let screenFrame: CGRect
        /// The centre of the handle, where the seam is looked up again to
        /// notice the windows moving.
        let anchor: CGPoint
        /// Where the cursor may be without the handle going away.
        let stayZone: CGRect
    }

    private var timer: Timer?
    private var lastMouseLocation = CGPoint.zero
    private var lastMoveTime: TimeInterval = 0
    private var dwellFired = false
    private var generation = 0

    private var panel: SnapDividerPanel?
    private var shown: Shown?

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

        confirmResizable(match) { [weak self] in
            self?.show(match, in: screenFrame)
        }
    }

    private func currentMatch(at point: CGPoint, in screenFrame: CGRect) -> Match? {
        Self.match(at: point, in: screenFrame,
                   windows: WindowUtil.getWindowList(),
                   configuredGap: Defaults.gapSize.cgFloat,
                   ignoring: Set([panel?.windowID].compactMap { $0 }))
    }

    /// Asks both apps whether their window can be resized and is not full
    /// screen, off the main thread, and calls `confirmed` on the main thread
    /// if so - unless the cursor has moved on in the meantime. The window
    /// list cannot answer either question, so this is only asked once a seam
    /// has been found.
    private func confirmResizable(_ match: Match, confirmed: @escaping () -> Void) {
        let requestGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let refusal = [match.left, match.right].compactMap { Self.refusal(for: $0) }.first
            DispatchQueue.main.async {
                guard let self,
                      self.generation == requestGeneration,
                      self.timer != nil
                else { return }
                if let refusal {
                    Logger.log("Snap divider: no handle at x=\(match.seam.position), \(refusal)")
                    return
                }
                confirmed()
            }
        }
    }

    /// Why the handle should stay away from this window, or nil if it can be
    /// resized. Resolves the window by pid directly (no shared window-list
    /// cache off the main thread), with AX timeouts so an unresponsive app
    /// cannot hold the answer up for long.
    private static func refusal(for info: WindowInfo) -> String? {
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
            return "\(name) was not found - it has closed, or its app did not answer in time"
        }
        if !windowElement.isResizable() { return "\(name) is not resizable" }
        if windowElement.isFullScreen == true { return "\(name) is full screen" }
        return nil
    }

    private func show(_ match: Match, in screenFrame: CGRect) {
        let seam = match.seam
        let pillFrame = SnapDividerGeometry.handleFrame(on: seam, within: match.clearSpan,
                                                        thickness: SnapDividerPanel.pillThickness,
                                                        lengthFraction: SnapDividerPanel.pillLengthFraction,
                                                        minimumLength: SnapDividerPanel.pillMinimumLength)
        let reach = seam.gap / 2 + Self.staySlop
        shown = Shown(match: match,
                      screenFrame: screenFrame,
                      anchor: CGPoint(x: seam.position, y: pillFrame.midY),
                      stayZone: CGRect(x: seam.position - reach,
                                       y: match.clearSpan.lowerBound,
                                       width: reach * 2,
                                       height: match.clearSpan.upperBound - match.clearSpan.lowerBound))
        let panel = self.panel ?? SnapDividerPanel()
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
        // The cursor may not have moved at all, so without this nothing would
        // look again. If the two still meet, the handle comes back on the
        // seam's new position after the usual dwell.
        lastMoveTime = ProcessInfo.processInfo.systemUptime
        dwellFired = false
    }

    private func dismiss() {
        // Invalidate any lookup in flight so a stale answer cannot bring the
        // handle back after a dismissal.
        generation += 1
        guard shown != nil else { return }
        shown = nil
        panel?.hide()
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
