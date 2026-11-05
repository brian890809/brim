import XCTest
import SwiftUI
@testable import CodexUsageMenuBar

final class NotchPreviewModeTests: XCTestCase {
    @MainActor
    func testFailedRefreshPreservesBothProvidersLastSuccessfulTimestamps() async throws {
        let now = Date()
        let codexSnapshot = CodexUsageSnapshot(shortTerm: nil,
            weekly: .init(usedPercent: 100, windowDurationMins: 10080,
                          resetsAt: now.addingTimeInterval(86400)),
            credits: .init(hasCredits: true, unlimited: false, balance: 12345),
            fetchedAt: now.addingTimeInterval(-120))
        let claudeSnapshot = ClaudeUsageSnapshot(version: 4, updatedAt: now.addingTimeInterval(-75),
            rateLimits: .init(fiveHour: .init(usedPercentage: 17,
                resetsAt: now.addingTimeInterval(3600)), weekly: nil, fable: nil))
        let provider = FailingRefreshPreviewProvider(codex: codexSnapshot, claude: claudeSnapshot)
        let codex = UsageStore(provider: provider)
        let claude = ClaudeUsageStore(monitor: false, provider: provider)
        XCTAssertNil(codex.snapshot)
        XCTAssertNil(claude.snapshot)
        await codex.refresh()
        await claude.refreshFromAccount()
        await codex.refresh()
        await claude.refreshFromAccount()
        XCTAssertEqual(codex.snapshot?.fetchedAt, codexSnapshot.fetchedAt)
        XCTAssertEqual(claude.snapshot?.updatedAt, claudeSnapshot.updatedAt)
        XCTAssertNotEqual(codex.snapshot?.fetchedAt, claude.snapshot?.updatedAt)
        XCTAssertNotNil(codex.errorMessage)
        XCTAssertNotNil(claude.errorMessage)

        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let presentation = NotchPresentationModel(defaults: defaults,
            layout: .init(compact: NotchPresentationLayout.fallback.compact, expandedTopReserve: 38))
        presentation.setPhase(.expanded)
        let view = NotchDashboardView(usageStore: codex, claudeStore: claude, presentation: presentation,
            onRefresh: {}, onOpenCodex: {}, onClose: {}, onQuit: {})
            .frame(width: 520, height: 212).background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/credit-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("failed-refresh-expanded.png"))
    }

    @MainActor
    func testCreditBalanceNativePreviews() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/credit-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cache = try NotchPreviewMode.writeClaudeCache(remainingPercent: 83, weeklyRemainingPercent: 46,
                                                       now: Date().addingTimeInterval(-75))
        defer { try? FileManager.default.removeItem(at: cache) }
        let claude = ClaudeUsageStore(cacheURL: cache, monitor: false)
        let layouts: [(String, NotchPresentationLayout)] = [
            ("notch", .init(compact: .init(hasHardwareNotch: true, surfaceHeight: 32,
                bottomClearance: 6, centerWidth: 179, wingWidth: 50, metricScale: 1,
                backingScaleFactor: 2), expandedTopReserve: 38)),
            ("external", .fallback)
        ]
        for (name, percent, credits): (String, Int, CodexCredits?) in [
            ("available", 55, .init(hasCredits: true, unlimited: false, balance: Decimal(string: "12345.6789"))),
            ("exhausted", 0, .init(hasCredits: true, unlimited: false, balance: Decimal(string: "12345.6789"))),
            ("empty", 0, .init(hasCredits: false, unlimited: false, balance: 0)),
            ("negative", 0, .init(hasCredits: false, unlimited: false, balance: Decimal(string: "-12.345"))),
            ("unlimited", 0, .init(hasCredits: true, unlimited: true, balance: nil)),
            ("unavailable", 0, nil),
            ("small", 0, .init(hasCredits: true, unlimited: false, balance: Decimal(string: "0.001")))
        ] {
            let codex = UsageStore(provider: PreviewRateLimitProvider(remainingPercent: percent, credits: credits))
            await codex.refresh()
            for (layoutName, layout) in layouts {
                let presentation = NotchPresentationModel(defaults: defaults, layout: layout)
                for content in [CompactNotchContent.codex, .codexCredits] {
                    presentation.compactContent = content
                    for phase in [NotchPresentationPhase.expanded, .compact] {
                        presentation.setPhase(phase)
                        let size = phase == .expanded
                            ? CGSize(width: 520, height: NotchGeometry.dashboardSize.height + layout.expandedTopReserve)
                            : CGSize(width: layout.notchGapWidth + 2 * layout.compact.wingWidth,
                                     height: layout.compact.surfaceHeight)
                        let view = NotchSurfaceView(usageStore: codex, claudeStore: claude, presentation: presentation,
                            onRefresh: {}, onOpenCodex: {}, onExpand: {}, onCompactHover: { _ in }, onClose: {}, onQuit: {})
                            .frame(width: size.width, height: size.height)
                            .transaction { $0.animation = nil }
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = 2
                        let image = try XCTUnwrap(renderer.nsImage)
                        XCTAssertEqual(image.size, size)
                        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                        let filename = "\(name)-\(layoutName)-\(content.rawValue)-\(phase == .expanded ? "expanded" : "compact").png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: output.appendingPathComponent(filename))
                    }
                }
            }
        }
    }

    @MainActor
    func testWindowTabNativePreviewsKeepApprovedDimensions() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let presentation = NotchPresentationModel(defaults: defaults, layout: .init(
            compact: NotchPresentationLayout.fallback.compact, expandedTopReserve: 38
        ))
        presentation.setPhase(.expanded)
        let codex = UsageStore(provider: PreviewRateLimitProvider(remainingPercent: 89))
        await codex.refresh()
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/window-tabs-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, period, weekly, fable): (String, ClaudeUsagePeriod, Int?, Int?) in [
            ("five-hour", .fiveHour, 46, 28), ("weekly", .weekly, 46, 28),
            ("fable", .fable, 46, 28), ("low", .fiveHour, 7, 4),
            ("unavailable", .fable, 46, nil), ("restored", .fiveHour, 46, 28)
        ] {
            let cache = try NotchPreviewMode.writeClaudeCache(
                remainingPercent: 83, weeklyRemainingPercent: weekly, fableRemainingPercent: fable
            )
            defer { try? FileManager.default.removeItem(at: cache) }
            let claude = ClaudeUsageStore(cacheURL: cache, monitor: false)
            presentation.claudeUsagePeriod = period
            XCTAssertEqual(ClaudeUsagePeriod.visiblePeriods(in: claude.snapshot),
                           fable == nil ? [.fiveHour, .weekly] : [.fiveHour, .weekly, .fable])
            XCTAssertEqual(period.resolved(in: claude.snapshot), fable == nil && period == .fable ? .fiveHour : period)
            let view = NotchDashboardView(usageStore: codex, claudeStore: claude, presentation: presentation,
                onRefresh: {}, onOpenCodex: {}, onClose: {}, onQuit: {})
                .frame(width: 520, height: 212)
                .background(.black)
                .clipShape(NotchSilhouette(topEarRadius: 18, bottomRadius: 22))
                .transaction { $0.animation = nil }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size, NSSize(width: 520, height: 212))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(bitmap.pixelsWide, 1040)
            XCTAssertEqual(bitmap.pixelsHigh, 424)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = "Native Claude tabs - " + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testOptionsAreInactiveWithoutLaunchArguments() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = NotchPreviewOptions(defaults: defaults)

        XCTAssertNil(options.codexRemainingPercent)
        XCTAssertNil(options.claudeRemainingPercent)
        XCTAssertFalse(options.isActive)
    }

    func testOptionsReadEachProviderIndependently() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("100", forKey: NotchPreviewOptions.codexArgumentKey)

        let options = NotchPreviewOptions(defaults: defaults)

        XCTAssertEqual(options.codexRemainingPercent, 100)
        XCTAssertNil(options.claudeRemainingPercent)
        XCTAssertTrue(options.isActive)
    }

    func testOptionsClampPercentagesToValidRange() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("250", forKey: NotchPreviewOptions.codexArgumentKey)
        defaults.set("-5", forKey: NotchPreviewOptions.claudeArgumentKey)

        let options = NotchPreviewOptions(defaults: defaults)

        XCTAssertEqual(options.codexRemainingPercent, 100)
        XCTAssertEqual(options.claudeRemainingPercent, 0)
    }

    func testPreviewProviderReportsConfiguredRemainingPercent() async throws {
        let provider = PreviewRateLimitProvider(remainingPercent: 100)

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.weekly?.remainingPercent, 100)
        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 100)
        XCTAssertNotNil(snapshot.weekly?.resetsAt)
    }

    @MainActor
    func testPreviewClaudeCacheDrivesTheClaudeStore() throws {
        let cacheURL = try NotchPreviewMode.writeClaudeCache(
            remainingPercent: 100
        )
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let store = ClaudeUsageStore(cacheURL: cacheURL, monitor: false)

        XCTAssertEqual(store.snapshot?.remainingPercent, 100)
        XCTAssertNil(store.errorMessage)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NotchPreviewModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private actor FailingRefreshPreviewProvider: RateLimitProviding, ClaudeUsageProviding {
    let codex: CodexUsageSnapshot
    let claude: ClaudeUsageSnapshot
    private var codexFetched = false
    private var claudeFetched = false

    init(codex: CodexUsageSnapshot, claude: ClaudeUsageSnapshot) {
        self.codex = codex
        self.claude = claude
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        guard !codexFetched else { throw CodexAppServerError.timedOut }
        codexFetched = true
        return codex
    }

    func fetchUsage(allowInteraction: Bool) async throws -> ClaudeUsageSnapshot {
        guard !claudeFetched else { throw ClaudeUsageAPIError.network }
        claudeFetched = true
        return claude
    }
}
