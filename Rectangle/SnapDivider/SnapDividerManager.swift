/// SnapDividerManager.swift

import Cocoa

/// Watches for the cursor resting on the seam between two side-by-side
/// windows. Does nothing unless the hidden `snapDivider` preference is on.
class SnapDividerManager {

    private static let tickInterval: TimeInterval = 0.1
    private static let dwellInterval: TimeInterval = 0.15
    private static let moveTolerance: CGFloat = 2
    /// How far from exact two facing edges may be, beyond the configured gap.
    /// Wide enough for a terminal that stopped a character cell short.
    private static let edgeTolerance: CGFloat = 8
    /// How far outside the gap the cursor still counts as on the seam.
    private static let hoverSlop: CGFloat = 4
    private static let minimumSpan: CGFloat = 100

    /// A seam and the two windows that form it.
    struct Match {
        let left: WindowInfo
        let right: WindowInfo
        let seam: SnapDividerGeometry.Seam
    }

    private var timer: Timer?
    private var lastMouseLocation = CGPoint.zero
    private var lastMoveTime: TimeInterval = 0
    private var dwellFired = false

    init() {
        NotificationCenter.default.addObserver(
            forName: .configImported,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.toggleListening()
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
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let location = NSEvent.mouseLocation
        if abs(location.x - lastMouseLocation.x) > Self.moveTolerance
            || abs(location.y - lastMouseLocation.y) > Self.moveTolerance {
            lastMouseLocation = location
            lastMoveTime = ProcessInfo.processInfo.systemUptime
            dwellFired = false
            return
        }

        guard !dwellFired,
              ProcessInfo.processInfo.systemUptime - lastMoveTime >= Self.dwellInterval
        else { return }
        dwellFired = true

        // A held button means a drag or a selection is under way somewhere
        // else, and a disabled front app means Rectangle stays out of the way.
        guard NSEvent.pressedMouseButtons == 0,
              !ApplicationToggle.shortcutsDisabled,
              let screen = (NSScreen.screens.first { NSPointInRect(location, $0.frame) }),
              let match = Self.match(at: location.screenFlipped,
                                     in: screen.frame.screenFlipped,
                                     windows: WindowUtil.getWindowList(),
                                     configuredGap: Defaults.gapSize.cgFloat),
              // The window list keeps reporting ordinary frames while Mission
              // Control shows the windows somewhere else entirely.
              !MissionControl.isActive
        else { return }

        Logger.log("Snap divider: seam at x=\(match.seam.position), gap \(match.seam.gap), between window \(match.left.id) (\(match.left.processName ?? "?")) and window \(match.right.id) (\(match.right.processName ?? "?"))")
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
        // cover the seam. Whatever shows through a gap from behind is fine.
        if let coveringIndex = frontmostIndex(at: point),
           coveringIndex < max(leftIndex, rightIndex),
           coveringIndex != leftIndex, coveringIndex != rightIndex {
            return nil
        }

        return Match(left: left, right: right, seam: seam)
    }
}
