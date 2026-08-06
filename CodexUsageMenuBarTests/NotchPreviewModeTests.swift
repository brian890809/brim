import XCTest
@testable import CodexUsageMenuBar

final class NotchPreviewModeTests: XCTestCase {
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
