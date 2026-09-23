import AppKit

struct NotchCompactLayout: Equatable {
    let hasHardwareNotch: Bool
    let surfaceHeight: CGFloat
    let bottomClearance: CGFloat
    let centerWidth: CGFloat
    let wingWidth: CGFloat
    let metricScale: CGFloat
    let backingScaleFactor: CGFloat
}

struct NotchGeometry: Equatable {
    static let dashboardSize = NSSize(width: 520, height: 150)
    static let fallbackNotchGapWidth: CGFloat = 156
    static let fallbackTopBarDepth: CGFloat = 25
    static let standardCompactHeight: CGFloat = 32
    static let minimumCompactScale: CGFloat = 0.5
    static let maximumCompactScale: CGFloat = 1.25

    // Keep the temporarily visible signals close to the physical notch. The
    // idle surface below yields all wing space back to native menu items.
    private static let standardCompactWingWidth: CGFloat = 50
    private static let minimumCompactWingWidth: CGFloat = 44
    private static let standardMenuBarDepth: CGFloat = 38
    private static let standardBottomClearance: CGFloat = 6
    private static let minimumBottomClearance: CGFloat = 3
    private static let maximumBottomClearance: CGFloat = 8
    private static let minimumSurfaceHeight: CGFloat = 15
    private static let minimumCompactWidthScale: CGFloat = 0.72
    private static let maximumCompactWidthScale: CGFloat = 1.15

    let screenFrame: NSRect
    let visibleFrame: NSRect
    let safeTopInset: CGFloat
    let auxiliaryTopLeftArea: NSRect?
    let auxiliaryTopRightArea: NSRect?
    let backingScaleFactor: CGFloat

    init(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        safeTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?,
        backingScaleFactor: CGFloat = 2
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeTopInset = safeTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.backingScaleFactor = max(1, backingScaleFactor)
    }

    init(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            backingScaleFactor: screen.backingScaleFactor
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

    private var hardwareNotchGapWidth: CGFloat? {
        guard
            hasNotch,
            let left = auxiliaryTopLeftArea,
            let right = auxiliaryTopRightArea
        else {
            return nil
        }

        return right.minX - left.maxX
    }

    var notchGapWidth: CGFloat {
        compactLayout.centerWidth
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

    /// Resolve the entire compact form from one measured snapshot. Hardware
    /// notch dimensions pass through unchanged. A synthetic notch preserves
    /// the native 32-in-38 vertical relationship and scales as one silhouette.
    var compactLayout: NotchCompactLayout {
        let scale = backingScaleFactor

        if let hardwareNotchGapWidth {
            let metricScale = compactMetricScale(for: safeTopInset)
            let widthScale = compactWidthScale(for: safeTopInset)

            return NotchCompactLayout(
                hasHardwareNotch: true,
                surfaceHeight: safeTopInset,
                bottomClearance: max(0, topBarDepth - safeTopInset),
                centerWidth: hardwareNotchGapWidth,
                wingWidth: alignedToBackingPixel(
                    max(
                        Self.minimumCompactWingWidth,
                        Self.standardCompactWingWidth * widthScale
                    )
                ),
                metricScale: metricScale,
                backingScaleFactor: scale
            )
        }

        let clearance = alignedToBackingPixel(
            min(
                Self.maximumBottomClearance,
                max(
                    Self.minimumBottomClearance,
                    topBarDepth
                        * Self.standardBottomClearance
                        / Self.standardMenuBarDepth
                )
            )
        )
        let surfaceHeight = alignedToBackingPixel(
            max(Self.minimumSurfaceHeight, topBarDepth - clearance)
        )
        let metricScale = compactMetricScale(for: surfaceHeight)
        let widthScale = compactWidthScale(for: surfaceHeight)

        return NotchCompactLayout(
            hasHardwareNotch: false,
            surfaceHeight: surfaceHeight,
            bottomClearance: max(0, topBarDepth - surfaceHeight),
            centerWidth: centeredPixelAlignedSpan(
                Self.fallbackNotchGapWidth * widthScale
            ),
            wingWidth: alignedToBackingPixel(
                max(
                    Self.minimumCompactWingWidth,
                    Self.standardCompactWingWidth * widthScale
                )
            ),
            metricScale: metricScale,
            backingScaleFactor: scale
        )
    }

    var collapsedSurfaceHeight: CGFloat {
        compactLayout.surfaceHeight
    }

    var bottomClearance: CGFloat {
        compactLayout.bottomClearance
    }

    var compactScale: CGFloat {
        compactLayout.metricScale
    }

    var compactWingWidth: CGFloat {
        compactLayout.wingWidth
    }

    var idleActivationWidth: CGFloat {
        notchGapWidth
    }

    /// Mouse-move monitors can use a generous hover corridor without making
    /// an invisible panel steal clicks from native menu-bar items.
    var idleHoverWidth: CGFloat {
        guard !hasNotch else { return notchGapWidth }
        return outwardCenteredPixelAlignedSpan(
            max(Self.fallbackNotchGapWidth, notchGapWidth)
        )
    }

    var compactSurfaceFrame: NSRect {
        let width = notchGapWidth + (2 * compactWingWidth)
        let height = collapsedSurfaceHeight

        return NSRect(
            x: horizontalAnchor - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    var idleSurfaceFrame: NSRect {
        let height = collapsedSurfaceHeight

        return NSRect(
            x: horizontalAnchor - notchGapWidth / 2,
            y: screenFrame.maxY - height,
            width: notchGapWidth,
            height: height
        )
    }

    /// A permission-free hover target that includes the clear strip beneath
    /// the hardware notch without occupying either menu-bar wing.
    var idleActivationFrame: NSRect {
        NSRect(
            x: horizontalAnchor - idleActivationWidth / 2,
            y: screenFrame.maxY - topBarDepth,
            width: idleActivationWidth,
            height: topBarDepth
        )
    }

    var idleHoverFrame: NSRect {
        NSRect(
            x: horizontalAnchor - idleHoverWidth / 2,
            y: screenFrame.maxY - topBarDepth,
            width: idleHoverWidth,
            height: topBarDepth
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

    private func alignedToBackingPixel(_ value: CGFloat) -> CGFloat {
        (value * backingScaleFactor).rounded() / backingScaleFactor
    }

    /// Keep a screen-centered span on whole backing pixels at both edges.
    private func centeredPixelAlignedSpan(_ value: CGFloat) -> CGFloat {
        let localAnchor = (horizontalAnchor - screenFrame.minX)
            * backingScaleFactor
        let physicalLeftEdge = (
            localAnchor - value * backingScaleFactor / 2
        ).rounded()
        return 2 * (localAnchor - physicalLeftEdge) / backingScaleFactor
    }

    private func outwardCenteredPixelAlignedSpan(_ value: CGFloat) -> CGFloat {
        let localAnchor = (horizontalAnchor - screenFrame.minX)
            * backingScaleFactor
        let anchorParity = Int((2 * localAnchor).rounded()) & 1
        var physicalWidth = Int(ceil(value * backingScaleFactor))

        if (physicalWidth & 1) != anchorParity {
            physicalWidth += 1
        }
        return CGFloat(physicalWidth) / backingScaleFactor
    }

    private func compactMetricScale(for surfaceHeight: CGFloat) -> CGFloat {
        min(
            Self.maximumCompactScale,
            max(
                Self.minimumCompactScale,
                surfaceHeight / Self.standardCompactHeight
            )
        )
    }

    private func compactWidthScale(for surfaceHeight: CGFloat) -> CGFloat {
        min(
            Self.maximumCompactWidthScale,
            max(
                Self.minimumCompactWidthScale,
                surfaceHeight / Self.standardCompactHeight
            )
        )
    }
}
