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
            NSRect(x: 602, y: 923, width: 267, height: 33)
        )
        XCTAssertEqual(
            geometry.expandedSurfaceFrame,
            NSRect(x: 475.5, y: 768, width: 520, height: 188)
        )
        XCTAssertEqual(geometry.compactSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(geometry.expandedSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(
            geometry.compactSurfaceFrame.minY - geometry.visibleFrame.maxY,
            NotchGeometry.compactBottomClearance
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
        XCTAssertEqual(geometry.compactSurfaceFrame.height, 35)
        XCTAssertEqual(geometry.compactSurfaceFrame.maxY, 900)
        XCTAssertEqual(geometry.expandedSurfaceFrame.height, 190)
        XCTAssertEqual(geometry.expandedSurfaceFrame.maxY, 900)
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
            NSRect(x: 838, y: 1060, width: 244, height: 20)
        )
        XCTAssertEqual(
            geometry.expandedSurfaceFrame,
            NSRect(x: 700, y: 905, width: 520, height: 175)
        )
        XCTAssertEqual(geometry.compactSurfaceFrame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(geometry.expandedSurfaceFrame.maxY, geometry.screenFrame.maxY)
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
        XCTAssertEqual(
            geometry.notchGapWidth,
            NotchGeometry.fallbackNotchGapWidth
        )
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
        XCTAssertEqual(reversed.compactSurfaceFrame.width, 244)
        XCTAssertEqual(oversized.compactSurfaceFrame.width, 244)
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

final class NotchSilhouetteTests: XCTestCase {
    func testSilhouetteFlaresAtTopAndNarrowsIntoItsBody() {
        let shape = NotchSilhouette(
            topEarRadius: NotchLayout.compactTopEarRadius,
            bottomRadius: NotchLayout.compactBottomRadius
        )
        let rect = CGRect(x: 0, y: 0, width: 267, height: 33)
        let path = shape.path(in: rect)

        XCTAssertTrue(path.contains(CGPoint(x: 7, y: 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 7, y: 22)))
        XCTAssertTrue(path.contains(CGPoint(x: 13, y: 22)))
    }

    func testVisibleContentInsetsAccountForTheSilhouetteEars() {
        XCTAssertEqual(
            NotchLayout.compactContentEdgeInset
                - NotchLayout.compactTopEarRadius,
            0
        )
        XCTAssertEqual(
            NotchLayout.footerHorizontalInset
                - NotchLayout.expandedTopEarRadius,
            18
        )
    }

    func testPresentationPhasesStageShellAndContentSeparately() {
        XCTAssertTrue(NotchPresentationPhase.compact.showsCompactContent)
        XCTAssertFalse(NotchPresentationPhase.compact.shellIsExpanded)

        XCTAssertTrue(NotchPresentationPhase.expanding.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.expanding.showsExpandedContent)

        XCTAssertTrue(NotchPresentationPhase.expanded.shellIsExpanded)
        XCTAssertTrue(NotchPresentationPhase.expanded.showsExpandedContent)

        XCTAssertTrue(NotchPresentationPhase.collapsing.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.collapsing.showsExpandedContent)

        XCTAssertFalse(NotchPresentationPhase.shrinking.shellIsExpanded)
        XCTAssertFalse(NotchPresentationPhase.shrinking.showsCompactContent)
    }
}
