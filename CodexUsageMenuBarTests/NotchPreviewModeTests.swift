import XCTest
import SwiftUI
@testable import CodexUsageMenuBar

final class NotchPreviewModeTests: XCTestCase {
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
            ("unavailable", .fable, 46, nil)
        ] {
            let cache = try NotchPreviewMode.writeClaudeCache(
                remainingPercent: 83, weeklyRemainingPercent: weekly, fableRemainingPercent: fable
            )
            defer { try? FileManager.default.removeItem(at: cache) }
            let claude = ClaudeUsageStore(cacheURL: cache, monitor: false)
            presentation.claudeUsagePeriod = period
            let view = NotchDashboardView(usageStore: codex, claudeStore: claude, presentation: presentation,
                onRefresh: {}, onOpenCodex: {}, onClose: {}, onQuit: {})
                .frame(width: 520, height: 188)
                .background(.black)
                .clipShape(NotchSilhouette(topEarRadius: 18, bottomRadius: 22))
                .transaction { $0.animation = nil }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size, NSSize(width: 520, height: 188))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(bitmap.pixelsWide, 1040)
            XCTAssertEqual(bitmap.pixelsHigh, 376)
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
