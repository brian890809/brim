import AppKit
import XCTest
@testable import CodexUsageMenuBar

final class NotchGeometryTests: XCTestCase {
    func testBuiltInNotchFixtureUsesTopAnchoredSurfaceFrames() {
        let geometry = makeBuiltInFixture()

        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(
            geometry.notchRect,
            NSRect(x: 646, y: 924, width: 179, height: 32)
        )
        XCTAssertEqual(geometry.horizontalAnchor, 735.5)
        XCTAssertEqual(
            geometry.compactSurfaceFrame,
            NSRect(x: 596, y: 924, width: 279, height: 32)
        )
        XCTAssertEqual(
            geometry.idleSurfaceFrame,
            NSRect(x: 646, y: 924, width: 179, height: 32)
        )
        XCTAssertEqual(
            geometry.idleActivationFrame,
            NSRect(x: 646, y: 918, width: 179, height: 38)
        )
        XCTAssertEqual(
            geometry.expandedSurfaceFrame,
            NSRect(x: 475.5, y: 768, width: 520, height: 188)
        )
        XCTAssertEqual(geometry.compactSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(geometry.expandedSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(geometry.idleSurfaceFrame, geometry.notchRect)
        XCTAssertEqual(geometry.collapsedSurfaceHeight, geometry.safeTopInset)
        XCTAssertEqual(
            geometry.compactLayout,
            NotchCompactLayout(
                hasHardwareNotch: true,
                surfaceHeight: 32,
                bottomClearance: 6,
                centerWidth: 179,
                wingWidth: 50,
                metricScale: 1,
                backingScaleFactor: 2
            )
        )
        XCTAssertEqual(
            geometry.compactSurfaceFrame.minY - geometry.visibleFrame.maxY,
            geometry.topBarDepth - geometry.safeTopInset
        )
        XCTAssertEqual(
            geometry.expandedSurfaceFrame.height - NotchGeometry.dashboardSize.height,
            geometry.topBarDepth
        )
    }

    func testNotchAnchorCanDifferFromScreenCenter() {
        let geometry = NotchGeometry(
            screenFrame: NSRect(x: -1440, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: -1440, y: 0, width: 1440, height: 870),
            safeTopInset: 24,
            auxiliaryTopLeftArea: NSRect(
                x: -1440,
                y: 876,
                width: 600,
                height: 24
            ),
            auxiliaryTopRightArea: NSRect(
                x: -700,
                y: 876,
                width: 700,
                height: 24
            )
        )

        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.horizontalAnchor, -770)
        XCTAssertEqual(geometry.compactSurfaceFrame.minX, -884)
        XCTAssertEqual(geometry.compactSurfaceFrame.height, 24)
        XCTAssertEqual(geometry.compactLayout.wingWidth, 44)
        XCTAssertEqual(geometry.compactLayout.metricScale, 0.75)
        XCTAssertEqual(
            geometry.idleSurfaceFrame,
            NSRect(x: -840, y: 876, width: 140, height: 24)
        )
        XCTAssertEqual(
            geometry.idleActivationFrame,
            NSRect(x: -840, y: 870, width: 140, height: 30)
        )
        XCTAssertEqual(geometry.expandedSurfaceFrame.minX, -1030)
    }

    func testCompactSurfaceGrowsWithTallerSafeAreaInset() {
        let geometry = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 860),
            safeTopInset: 40,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 860, width: 500, height: 40),
            auxiliaryTopRightArea: NSRect(x: 680, y: 860, width: 520, height: 40)
        )

        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.compactSurfaceFrame.height, 40)
        XCTAssertEqual(geometry.compactSurfaceFrame.maxY, 900)
        XCTAssertEqual(geometry.compactLayout.wingWidth, 57.5)
        XCTAssertEqual(geometry.compactLayout.metricScale, 1.25)
        XCTAssertEqual(
            geometry.idleSurfaceFrame,
            NSRect(x: 500, y: 860, width: 180, height: 40)
        )
        XCTAssertEqual(
            geometry.idleActivationFrame,
            NSRect(x: 500, y: 860, width: 180, height: 40)
        )
        XCTAssertEqual(geometry.expandedSurfaceFrame.height, 190)
        XCTAssertEqual(geometry.expandedSurfaceFrame.maxY, 900)
    }

    func testCollapsedSurfaceTracksEachReportedCameraHousingDepth() {
        for safeTopInset: CGFloat in [24, 32, 38, 40] {
            let menuBarDepth = safeTopInset + 6
            let geometry = NotchGeometry(
                screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 900),
                visibleFrame: NSRect(
                    x: 0,
                    y: 0,
                    width: 1200,
                    height: 900 - menuBarDepth
                ),
                safeTopInset: safeTopInset,
                auxiliaryTopLeftArea: NSRect(
                    x: 0,
                    y: 900 - safeTopInset,
                    width: 510,
                    height: safeTopInset
                ),
                auxiliaryTopRightArea: NSRect(
                    x: 690,
                    y: 900 - safeTopInset,
                    width: 510,
                    height: safeTopInset
                )
            )

            XCTAssertTrue(geometry.hasNotch)
            XCTAssertEqual(geometry.collapsedSurfaceHeight, safeTopInset)
            XCTAssertEqual(geometry.compactSurfaceFrame.height, safeTopInset)
            XCTAssertEqual(geometry.idleSurfaceFrame.height, safeTopInset)
            XCTAssertEqual(geometry.bottomClearance, 6)
            XCTAssertEqual(geometry.notchGapWidth, 180)
        }
    }

    func testNotchlessScreenUsesCenteredTopAnchoredSurfaceFrames() {
        let geometry = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1055),
            safeTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertFalse(geometry.hasNotch)
        XCTAssertNil(geometry.notchRect)
        XCTAssertEqual(
            geometry.compactSurfaceFrame,
            NSRect(x: 860, y: 1059, width: 200, height: 21)
        )
        XCTAssertEqual(
            geometry.idleSurfaceFrame,
            NSRect(x: 904, y: 1059, width: 112, height: 21)
        )
        XCTAssertEqual(
            geometry.idleActivationFrame,
            NSRect(x: 904, y: 1055, width: 112, height: 25)
        )
        XCTAssertEqual(
            geometry.idleHoverFrame,
            NSRect(x: 882, y: 1055, width: 156, height: 25)
        )
        XCTAssertEqual(
            geometry.expandedSurfaceFrame,
            NSRect(x: 700, y: 905, width: 520, height: 175)
        )
        XCTAssertEqual(geometry.compactSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(geometry.expandedSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(geometry.bottomClearance, 4)
        XCTAssertEqual(geometry.compactScale, 21 / 32)
    }

    func testNotchlessSurfaceScalesAsOnePixelAlignedForm() {
        let fixtures: [(
            menuBar: CGFloat,
            surface: CGFloat,
            clearance: CGFloat,
            center: CGFloat,
            wing: CGFloat,
            total: CGFloat,
            x: CGFloat,
            y: CGFloat
        )] = [
            (20, 17, 3, 112, 44, 200, 860, 1063),
            (25, 21, 4, 112, 44, 200, 860, 1059),
            (32, 27, 5, 132, 44, 220, 850, 1053),
            (38, 32, 6, 156, 50, 256, 832, 1048),
        ]

        for backingScale: CGFloat in [1, 2] {
            for fixture in fixtures {
                let geometry = makeNotchlessFixture(
                    menuBarDepth: fixture.menuBar,
                    backingScale: backingScale
                )

                XCTAssertFalse(geometry.hasNotch)
                XCTAssertEqual(geometry.topBarDepth, fixture.menuBar)
                XCTAssertEqual(geometry.collapsedSurfaceHeight, fixture.surface)
                XCTAssertEqual(geometry.bottomClearance, fixture.clearance)
                XCTAssertEqual(geometry.notchGapWidth, fixture.center)
                XCTAssertEqual(geometry.compactWingWidth, fixture.wing)
                XCTAssertEqual(
                    geometry.compactSurfaceFrame,
                    NSRect(
                        x: fixture.x,
                        y: fixture.y,
                        width: fixture.total,
                        height: fixture.surface
                    )
                )
                XCTAssertEqual(
                    geometry.idleActivationFrame.height,
                    fixture.menuBar
                )
                XCTAssertGreaterThanOrEqual(
                    geometry.idleHoverFrame.width,
                    NotchGeometry.fallbackNotchGapWidth
                )
                XCTAssertEqual(
                    geometry.idleActivationFrame.width,
                    geometry.idleSurfaceFrame.width
                )
                XCTAssertEqual(
                    geometry.compactScale,
                    fixture.surface / NotchGeometry.standardCompactHeight
                )

                for value in [
                    geometry.collapsedSurfaceHeight,
                    geometry.bottomClearance,
                    geometry.notchGapWidth,
                    geometry.compactWingWidth,
                ] {
                    XCTAssertEqual(
                        value * backingScale,
                        (value * backingScale).rounded()
                    )
                }
            }
        }
    }

    func testNotchlessLayoutUsesHalfPointsOnlyOnRetinaScreens() {
        let oneX = makeNotchlessFixture(
            menuBarDepth: 21,
            backingScale: 1
        )
        let twoX = makeNotchlessFixture(
            menuBarDepth: 21,
            backingScale: 2
        )

        XCTAssertEqual(oneX.bottomClearance, 3)
        XCTAssertEqual(oneX.collapsedSurfaceHeight, 18)
        XCTAssertEqual(twoX.bottomClearance, 3.5)
        XCTAssertEqual(twoX.collapsedSurfaceHeight, 17.5)

        for (geometry, backingScale) in [(oneX, CGFloat(1)), (twoX, 2)] {
            for edge in [
                geometry.compactSurfaceFrame.minX,
                geometry.compactSurfaceFrame.maxX,
                geometry.compactSurfaceFrame.minY,
                geometry.compactSurfaceFrame.maxY,
                geometry.idleSurfaceFrame.minX,
                geometry.idleSurfaceFrame.maxX,
            ] {
                XCTAssertEqual(
                    edge * backingScale,
                    (edge * backingScale).rounded()
                )
            }
        }
    }

    func testOddPhysicalScreenWidthKeepsBothCenteredEdgesOnPixels() {
        let geometry = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1001, height: 800),
            visibleFrame: NSRect(x: 0, y: 0, width: 1001, height: 775),
            safeTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            backingScaleFactor: 1
        )

        XCTAssertEqual(geometry.horizontalAnchor, 500.5)
        XCTAssertEqual(geometry.notchGapWidth, 113)
        XCTAssertEqual(
            geometry.idleSurfaceFrame,
            NSRect(x: 444, y: 779, width: 113, height: 21)
        )
        XCTAssertEqual(
            geometry.compactSurfaceFrame,
            NSRect(x: 400, y: 779, width: 201, height: 21)
        )

        for frame in [
            geometry.idleSurfaceFrame,
            geometry.compactSurfaceFrame,
            geometry.idleActivationFrame,
            geometry.idleHoverFrame,
        ] {
            XCTAssertEqual(frame.minX, frame.minX.rounded())
            XCTAssertEqual(frame.maxX, frame.maxX.rounded())
        }
        XCTAssertEqual(geometry.idleHoverFrame.width, 157)
        XCTAssertGreaterThanOrEqual(
            geometry.idleHoverFrame.width,
            NotchGeometry.fallbackNotchGapWidth
        )
    }

    func testNotchlessSurfaceFallsBackWhenMenuBarDepthIsInvalid() {
        let geometry = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1075),
            safeTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertEqual(geometry.topBarDepth, NotchGeometry.fallbackTopBarDepth)
        XCTAssertEqual(geometry.collapsedSurfaceHeight, 21)
        XCTAssertEqual(geometry.bottomClearance, 4)
        XCTAssertEqual(geometry.notchGapWidth, 112)
        XCTAssertEqual(geometry.compactSurfaceFrame.width, 200)
    }

    func testOneMissingAuxiliaryAreaFallsBackSafely() {
        let fixture = makeBuiltInFixture()
        let geometry = NotchGeometry(
            screenFrame: fixture.screenFrame,
            visibleFrame: fixture.visibleFrame,
            safeTopInset: fixture.safeTopInset,
            auxiliaryTopLeftArea: fixture.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: nil
        )

        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.notchGapWidth, 156)
        XCTAssertGreaterThan(geometry.compactSurfaceFrame.width, 0)
    }

    func testReversedAndOversizedGapsFallBackSafely() {
        let reversed = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 776),
            safeTopInset: 24,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 776, width: 600, height: 24),
            auxiliaryTopRightArea: NSRect(x: 500, y: 776, width: 500, height: 24)
        )
        let oversized = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 776),
            safeTopInset: 24,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 776, width: 100, height: 24),
            auxiliaryTopRightArea: NSRect(x: 700, y: 776, width: 300, height: 24)
        )

        XCTAssertFalse(reversed.hasNotch)
        XCTAssertFalse(oversized.hasNotch)
        XCTAssertEqual(reversed.compactSurfaceFrame.width, 200)
        XCTAssertEqual(oversized.compactSurfaceFrame.width, 200)
    }

    private func makeNotchlessFixture(
        menuBarDepth: CGFloat,
        backingScale: CGFloat
    ) -> NotchGeometry {
        NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(
                x: 0,
                y: 0,
                width: 1920,
                height: 1080 - menuBarDepth
            ),
            safeTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            backingScaleFactor: backingScale
        )
    }

    private func makeBuiltInFixture() -> NotchGeometry {
        NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: NSRect(x: 0, y: 76, width: 1470, height: 842),
            safeTopInset: 32,
            auxiliaryTopLeftArea: NSRect(
                x: 0,
                y: 924,
                width: 646,
                height: 32
            ),
            auxiliaryTopRightArea: NSRect(
                x: 825,
                y: 924,
                width: 645,
                height: 32
            )
        )
    }
}

final class CompactProviderTests: XCTestCase {
    @MainActor
    func testCodexIsTheDefaultCompactProvider() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = NotchPresentationModel(defaults: defaults)

        XCTAssertEqual(presentation.compactProvider, .codex)
        XCTAssertFalse(presentation.isCompactContentLocked)
        XCTAssertEqual(presentation.phase, .idle)
    }

    @MainActor
    func testCompactProviderSelectionPersists() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = NotchPresentationModel(defaults: defaults)
        presentation.compactProvider = .claude

        let restored = NotchPresentationModel(defaults: defaults)
        XCTAssertEqual(restored.compactProvider, .claude)
    }

    @MainActor
    func testAutomaticRefreshIsOptInAndPersists() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = NotchPresentationModel(defaults: defaults)
        XCTAssertFalse(presentation.isAutomaticRefreshEnabled)

        presentation.isAutomaticRefreshEnabled = true

        let restored = NotchPresentationModel(defaults: defaults)
        XCTAssertTrue(restored.isAutomaticRefreshEnabled)
    }

    @MainActor
    func testUnknownPersistedProviderFallsBackToCodex() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "unknown-provider",
            forKey: NotchPresentationModel.compactProviderKey
        )

        let presentation = NotchPresentationModel(defaults: defaults)

        XCTAssertEqual(presentation.compactProvider, .codex)
    }

    @MainActor
    func testCompactContentLockPersistsAndRestoresVisibleState() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = NotchPresentationModel(defaults: defaults)
        presentation.isCompactContentLocked = true

        let restored = NotchPresentationModel(defaults: defaults)

        XCTAssertTrue(restored.isCompactContentLocked)
        XCTAssertEqual(restored.phase, .compact)
    }

    @MainActor
    func testCompactAutoHidePolicyHonorsPointerAndLock() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = NotchPresentationModel(defaults: defaults)

        XCTAssertTrue(
            presentation.shouldHideCompact(pointerIsInside: false)
        )
        XCTAssertFalse(
            presentation.shouldHideCompact(pointerIsInside: true)
        )

        presentation.isCompactContentLocked = true
        XCTAssertFalse(
            presentation.shouldHideCompact(pointerIsInside: false)
        )
    }

    @MainActor
    func testLayoutSnapshotUpdatesAtomicallyAcrossScreens() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let nativeLayout = NotchPresentationLayout(
            compact: NotchCompactLayout(
                hasHardwareNotch: true,
                surfaceHeight: 32,
                bottomClearance: 6,
                centerWidth: 179,
                wingWidth: 50,
                metricScale: 1,
                backingScaleFactor: 2
            ),
            expandedTopReserve: 38
        )
        let presentation = NotchPresentationModel(
            defaults: defaults,
            layout: nativeLayout
        )
        let externalLayout = NotchPresentationLayout(
            compact: NotchCompactLayout(
                hasHardwareNotch: false,
                surfaceHeight: 21,
                bottomClearance: 4,
                centerWidth: 112,
                wingWidth: 44,
                metricScale: 21 / 32,
                backingScaleFactor: 2
            ),
            expandedTopReserve: 25
        )

        presentation.updateLayout(externalLayout)
        XCTAssertEqual(presentation.layout, externalLayout)
        XCTAssertEqual(presentation.notchGapWidth, 112)
        XCTAssertEqual(presentation.expandedTopReserve, 25)

        presentation.setPhase(.expanding)
        XCTAssertEqual(presentation.layout, externalLayout)

        presentation.updateLayout(nativeLayout)
        XCTAssertEqual(presentation.layout, nativeLayout)
    }

    func testEachProviderSelectsItsOwnRemainingPercentage() {
        XCTAssertEqual(
            CompactProvider.codex.remainingPercentage(codex: 91, claude: 37),
            91
        )
        XCTAssertEqual(
            CompactProvider.claude.remainingPercentage(codex: 91, claude: 37),
            37
        )
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NotchPresentationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

final class NotchFooterHelpModelTests: XCTestCase {
    @MainActor
    func testHoveringAControlPresentsAndClearsItsExplanation() {
        let model = NotchFooterHelpModel()

        model.setHover("Refresh usage now", isHovering: true)
        XCTAssertEqual(model.text, "Refresh usage now")

        model.setHover("Refresh usage now", isHovering: false)
        XCTAssertNil(model.text)
    }

    @MainActor
    func testLateExitDoesNotClearTheNewerHoveredExplanation() {
        let model = NotchFooterHelpModel()

        model.setHover("Refresh usage now", isHovering: true)
        model.setHover("Open Codex", isHovering: true)
        model.setHover("Refresh usage now", isHovering: false)

        XCTAssertEqual(model.text, "Open Codex")
    }

    @MainActor
    func testClearingTheDashboardDismissesTheHoveredExplanation() {
        let model = NotchFooterHelpModel()
        model.setHover("Collapse the usage dashboard", isHovering: true)

        model.clear()

        XCTAssertNil(model.text)
    }
}

final class NotchCompactLayoutTests: XCTestCase {
    func testPercentBaselineMovesDownByOnePhysicalPixel() {
        for backingScale: CGFloat in [1, 2] {
            let geometry = makeNotchlessFixture(
                menuBarDepth: 25,
                backingScale: backingScale
            )
            let layout = NotchPresentationLayout(
                compact: geometry.compactLayout,
                expandedTopReserve: geometry.topBarDepth
            )

            XCTAssertEqual(
                NotchLayout.compactPercentVerticalOffset(for: layout)
                    * backingScale,
                1
            )
        }
    }

    func testCompactWingFitsWidestPercentLabelAtEveryTestedScale() {
        for backingScale: CGFloat in [1, 2] {
            for menuBarDepth: CGFloat in [20, 25, 32, 38] {
                let geometry = makeNotchlessFixture(
                    menuBarDepth: menuBarDepth,
                    backingScale: backingScale
                )
                let layout = NotchPresentationLayout(
                    compact: geometry.compactLayout,
                    expandedTopReserve: geometry.topBarDepth
                )
                let metrics = NotchLayout.compactMetrics(for: layout)
                let availableLabelWidth = geometry.compactWingWidth
                    - metrics.contentEdgeInset
                let font = NSFont.monospacedDigitSystemFont(
                    ofSize: metrics.percentFontSize,
                    weight: .medium
                )
                let widestLabelWidth = ("100%" as NSString)
                    .size(withAttributes: [.font: font])
                    .width

                XCTAssertGreaterThanOrEqual(
                    availableLabelWidth,
                    widestLabelWidth * metrics.percentMinimumScale,
                    "100% did not fit a \(menuBarDepth)-point bar at \(backingScale)x"
                )
            }
        }
    }

    func testNativeThirtyTwoPointProfileRemainsExact() {
        let layout = NotchPresentationLayout(
            compact: NotchCompactLayout(
                hasHardwareNotch: true,
                surfaceHeight: 32,
                bottomClearance: 6,
                centerWidth: 179,
                wingWidth: 50,
                metricScale: 1,
                backingScaleFactor: 2
            ),
            expandedTopReserve: 38
        )

        XCTAssertEqual(
            NotchLayout.compactMetrics(for: layout),
            NotchCompactMetrics(
                topEarRadius: 12,
                bottomRadius: 14,
                contentEdgeInset: 16,
                logoSize: 20,
                percentFontSize: 14,
                percentMinimumScale: 0.8,
                contentRevealOffset: 3
            )
        )
    }

    func testSyntheticMetricsScaleWithResolvedSurfaceHeight() {
        let fixtures: [(
            menuBar: CGFloat,
            expected: NotchCompactMetrics
        )] = [
            (
                20,
                NotchCompactMetrics(
                    topEarRadius: 5.5,
                    bottomRadius: 8,
                    contentEdgeInset: 10,
                    logoSize: 16,
                    percentFontSize: NotchLayout.menuBarPercentFontSize,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 2
                )
            ),
            (
                25,
                NotchCompactMetrics(
                    topEarRadius: 7,
                    bottomRadius: 9,
                    contentEdgeInset: 10.5,
                    logoSize: 16,
                    percentFontSize: NotchLayout.menuBarPercentFontSize,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 2
                )
            ),
            (
                32,
                NotchCompactMetrics(
                    topEarRadius: 9,
                    bottomRadius: 12,
                    contentEdgeInset: 13.5,
                    logoSize: 17,
                    percentFontSize: NotchLayout.menuBarPercentFontSize,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 2.5
                )
            ),
            (
                38,
                NotchCompactMetrics(
                    topEarRadius: 10.5,
                    bottomRadius: 14,
                    contentEdgeInset: 16,
                    logoSize: 20,
                    percentFontSize: 14,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 3
                )
            ),
        ]

        for fixture in fixtures {
            let geometry = makeNotchlessFixture(
                menuBarDepth: fixture.menuBar,
                backingScale: 2
            )
            let layout = NotchPresentationLayout(
                compact: geometry.compactLayout,
                expandedTopReserve: geometry.topBarDepth
            )

            XCTAssertEqual(
                NotchLayout.compactMetrics(for: layout),
                fixture.expected
            )
        }
    }

    func testSyntheticMetricsStayOnBackingPixelGrid() {
        for backingScale: CGFloat in [1, 2] {
            for menuBarDepth: CGFloat in [20, 25, 32, 38] {
                let geometry = makeNotchlessFixture(
                    menuBarDepth: menuBarDepth,
                    backingScale: backingScale
                )
                let metrics = NotchLayout.compactMetrics(
                    for: NotchPresentationLayout(
                        compact: geometry.compactLayout,
                        expandedTopReserve: geometry.topBarDepth
                    )
                )

                for value in [
                    metrics.topEarRadius,
                    metrics.bottomRadius,
                    metrics.contentEdgeInset,
                    metrics.logoSize,
                    metrics.percentFontSize,
                    metrics.contentRevealOffset,
                ] {
                    XCTAssertEqual(
                        value * backingScale,
                        (value * backingScale).rounded()
                    )
                }
            }
        }
    }

    func testOneXMetricsUseWholePointRounding() {
        let fixtures: [(CGFloat, NotchCompactMetrics)] = [
            (
                20,
                NotchCompactMetrics(
                    topEarRadius: 6,
                    bottomRadius: 8,
                    contentEdgeInset: 10,
                    logoSize: 16,
                    percentFontSize: NotchLayout.menuBarPercentFontSize,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 2
                )
            ),
            (
                25,
                NotchCompactMetrics(
                    topEarRadius: 7,
                    bottomRadius: 9,
                    contentEdgeInset: 11,
                    logoSize: 16,
                    percentFontSize: NotchLayout.menuBarPercentFontSize,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 2
                )
            ),
            (
                32,
                NotchCompactMetrics(
                    topEarRadius: 9,
                    bottomRadius: 12,
                    contentEdgeInset: 14,
                    logoSize: 17,
                    percentFontSize: NotchLayout.menuBarPercentFontSize,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 3
                )
            ),
            (
                38,
                NotchCompactMetrics(
                    topEarRadius: 11,
                    bottomRadius: 14,
                    contentEdgeInset: 16,
                    logoSize: 20,
                    percentFontSize: 14,
                    percentMinimumScale: 0.8,
                    contentRevealOffset: 3
                )
            ),
        ]

        for (menuBarDepth, expected) in fixtures {
            let geometry = makeNotchlessFixture(
                menuBarDepth: menuBarDepth,
                backingScale: 1
            )
            let metrics = NotchLayout.compactMetrics(
                for: NotchPresentationLayout(
                    compact: geometry.compactLayout,
                    expandedTopReserve: geometry.topBarDepth
                )
            )

            XCTAssertEqual(metrics, expected)
        }
    }

    private func makeNotchlessFixture(
        menuBarDepth: CGFloat,
        backingScale: CGFloat
    ) -> NotchGeometry {
        NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(
                x: 0,
                y: 0,
                width: 1920,
                height: 1080 - menuBarDepth
            ),
            safeTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            backingScaleFactor: backingScale
        )
    }
}

final class NotchWindowBehaviorTests: XCTestCase {
    @MainActor
    func testOverlaySurfacesStayPutDuringDesktopReveal() {
        let behavior = NotchWindowController.overlayCollectionBehavior

        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertFalse(behavior.contains(.transient))
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.canJoinAllApplications))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }
}

final class NotchSilhouetteTests: XCTestCase {
    func testSilhouetteFlaresAtTopAndNarrowsIntoItsBody() {
        let layout = nativePresentationLayout()
        let metrics = NotchLayout.compactMetrics(for: layout)
        let shape = NotchSilhouette(
            topEarRadius: metrics.topEarRadius,
            bottomRadius: metrics.bottomRadius
        )
        let rect = CGRect(x: 0, y: 0, width: 279, height: 32)
        let path = shape.path(in: rect)

        XCTAssertTrue(path.contains(CGPoint(x: 7, y: 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 7, y: 22)))
        XCTAssertTrue(path.contains(CGPoint(x: 13, y: 22)))
    }

    func testNotchlessSilhouetteScalesItsInnerEdge() {
        let layout = externalPresentationLayout()
        let metrics = NotchLayout.compactMetrics(for: layout)
        let shape = NotchSilhouette(
            topEarRadius: metrics.topEarRadius,
            bottomRadius: metrics.bottomRadius
        )
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 200, height: 21))

        XCTAssertFalse(path.contains(CGPoint(x: 6, y: 10)))
        XCTAssertTrue(path.contains(CGPoint(x: 8, y: 10)))
    }

    func testVisibleContentBreathingRoomScalesWithTheSilhouette() {
        let nativeLayout = nativePresentationLayout()
        let nativeMetrics = NotchLayout.compactMetrics(for: nativeLayout)
        let nativeEar = min(
            nativeMetrics.topEarRadius,
            nativeLayout.compact.surfaceHeight / 3
        )
        let nativeBreathingRoom = nativeMetrics.contentEdgeInset - nativeEar

        let externalLayout = externalPresentationLayout()
        let externalMetrics = NotchLayout.compactMetrics(for: externalLayout)
        let externalEar = min(
            externalMetrics.topEarRadius,
            externalLayout.compact.surfaceHeight / 3
        )
        let externalBreathingRoom = externalMetrics.contentEdgeInset
            - externalEar

        XCTAssertEqual(
            externalBreathingRoom,
            nativeBreathingRoom * externalLayout.compact.metricScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchLayout.footerHorizontalInset
                - NotchLayout.expandedTopEarRadius,
            18
        )
    }

    func testPresentationPhasesStageShellAndContentSeparately() {
        XCTAssertFalse(NotchPresentationPhase.idle.showsCompactContent)
        XCTAssertFalse(NotchPresentationPhase.idle.shellIsExpanded)
        XCTAssertTrue(NotchPresentationPhase.idle.showsIdleOpener)

        XCTAssertFalse(
            NotchPresentationPhase.revealingCompact.showsCompactContent
        )
        XCTAssertFalse(
            NotchPresentationPhase.revealingCompact.shellIsExpanded
        )
        XCTAssertTrue(
            NotchPresentationPhase.revealingCompact.showsIdleOpener
        )

        XCTAssertTrue(NotchPresentationPhase.compact.showsCompactContent)
        XCTAssertFalse(NotchPresentationPhase.compact.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.compact.showsIdleOpener)

        XCTAssertTrue(NotchPresentationPhase.expanding.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.expanding.showsExpandedContent)

        XCTAssertTrue(NotchPresentationPhase.expanded.shellIsExpanded)
        XCTAssertTrue(NotchPresentationPhase.expanded.showsExpandedContent)

        XCTAssertTrue(NotchPresentationPhase.collapsing.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.collapsing.showsExpandedContent)

        XCTAssertFalse(NotchPresentationPhase.shrinking.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.shrinking.showsCompactContent)

        XCTAssertFalse(
            NotchPresentationPhase.hidingCompact.showsCompactContent
        )
        XCTAssertTrue(NotchPresentationPhase.hidingCompact.usesIdleFrame)
        XCTAssertTrue(NotchPresentationPhase.hidingCompact.showsIdleOpener)
    }

    func testCompactVisibilityGracePeriodIsTwoSeconds() {
        XCTAssertEqual(
            NotchMotion.idleReturnDelayNanoseconds,
            2_000_000_000
        )
    }

    private func nativePresentationLayout() -> NotchPresentationLayout {
        NotchPresentationLayout(
            compact: NotchCompactLayout(
                hasHardwareNotch: true,
                surfaceHeight: 32,
                bottomClearance: 6,
                centerWidth: 179,
                wingWidth: 50,
                metricScale: 1,
                backingScaleFactor: 2
            ),
            expandedTopReserve: 38
        )
    }

    private func externalPresentationLayout() -> NotchPresentationLayout {
        NotchPresentationLayout(
            compact: NotchCompactLayout(
                hasHardwareNotch: false,
                surfaceHeight: 21,
                bottomClearance: 4,
                centerWidth: 112,
                wingWidth: 44,
                metricScale: 21 / 32,
                backingScaleFactor: 2
            ),
            expandedTopReserve: 25
        )
    }
}
