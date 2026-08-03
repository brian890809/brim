import AppKit

struct NotchGeometry: Equatable {
    static let dashboardSize = NSSize(width: 520, height: 150)
    static let fallbackNotchGapWidth: CGFloat = 156
    static let fallbackTopBarDepth: CGFloat = 25
    static let compactBottomClearance: CGFloat = 5

    // Keep the always-visible signals close to the physical notch so the
    // compact surface yields as much space as possible to native menu items.
    private static let compactWingWidth: CGFloat = 44

    let screenFrame: NSRect
    let visibleFrame: NSRect
    let safeTopInset: CGFloat
    let auxiliaryTopLeftArea: NSRect?
    let auxiliaryTopRightArea: NSRect?

    init(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        safeTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeTopInset = safeTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    var hasNotch: Bool {
        guard
            safeTopInset > 0,
            let left = auxiliaryTopLeftArea,
            let right = auxiliaryTopRightArea
        else {
            return false
        }

        let gap = right.minX - left.maxX
        let tolerance: CGFloat = 2
        let areasReachScreenTop =
            abs(left.maxY - screenFrame.maxY) <= tolerance
            && abs(right.maxY - screenFrame.maxY) <= tolerance
        let areasStayOnScreen =
            left.minX >= screenFrame.minX - tolerance
            && right.maxX <= screenFrame.maxX + tolerance

        return areasReachScreenTop
            && areasStayOnScreen
            && gap >= 40
            && gap < screenFrame.width * 0.5
    }

    var notchGapWidth: CGFloat {
        guard
            hasNotch,
            let left = auxiliaryTopLeftArea,
            let right = auxiliaryTopRightArea
        else {
            return Self.fallbackNotchGapWidth
        }

        return right.minX - left.maxX
    }

    var notchRect: NSRect? {
        guard
            hasNotch,
            let left = auxiliaryTopLeftArea,
            let right = auxiliaryTopRightArea
        else {
            return nil
        }

        return NSRect(
            x: left.maxX,
            y: screenFrame.maxY - safeTopInset,
            width: right.minX - left.maxX,
            height: safeTopInset
        )
    }

    var horizontalAnchor: CGFloat {
        notchRect?.midX ?? screenFrame.midX
    }

    var topBarDepth: CGFloat {
        let measuredDepth = screenFrame.maxY - visibleFrame.maxY
        let isUsableMeasurement = measuredDepth >= 18
            && measuredDepth <= 80
            && visibleFrame.maxY > screenFrame.minY

        if isUsableMeasurement {
            return measuredDepth
        }
        if hasNotch {
            return safeTopInset
        }
        return Self.fallbackTopBarDepth
    }

    var compactSurfaceFrame: NSRect {
        let width = notchGapWidth + (2 * Self.compactWingWidth)
        let height = max(1, topBarDepth - Self.compactBottomClearance)

        return NSRect(
            x: horizontalAnchor - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    var expandedSurfaceFrame: NSRect {
        let height = topBarDepth + Self.dashboardSize.height

        return NSRect(
            x: horizontalAnchor - Self.dashboardSize.width / 2,
            y: screenFrame.maxY - height,
            width: Self.dashboardSize.width,
            height: height
        )
    }
}
