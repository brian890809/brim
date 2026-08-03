import AppKit
import Foundation
import XCTest
@testable import CodexUsageMenuBar

final class CodexUsageSnapshotTests: XCTestCase {
    func testMonochromeGlyphHasSixteenPointTemplateImage() throws {
        let source = NSImage(size: NSSize(width: 1_024, height: 1_024))
        let image = try XCTUnwrap(MonochromeBrandImage.make(from: source))

        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertTrue(image.isTemplate)
    }

    func testPrefersCodexBucketAndClassifiesWindowsByDuration() throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "limitId": "legacy",
                "primary": {"usedPercent": 99, "windowDurationMins": 300, "resetsAt": 100}
              },
              "rateLimitsByLimitId": {
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "primary": {"usedPercent": 1, "windowDurationMins": 10080, "resetsAt": 200}
                },
                "codex": {
                  "limitId": "codex",
                  "primary": {"usedPercent": 45, "windowDurationMins": 10080, "resetsAt": 300},
                  "secondary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 400},
                  "futureField": {"safe": true}
                }
              },
              "futureTopLevelField": "ignored"
            }
            """
        )

        let snapshot = CodexUsageSnapshot(
            response: response,
            fetchedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 90)
        XCTAssertEqual(snapshot.shortTerm?.windowDurationMins, 300)
        XCTAssertEqual(snapshot.shortTerm?.resetsAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 55)
        XCTAssertEqual(snapshot.weekly?.windowDurationMins, 10_080)
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 500))
    }

    func testSingleWeeklyPrimaryDoesNotMasqueradeAsShortTerm() throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 45, "windowDurationMins": 10080, "resetsAt": null},
                "secondary": null
              },
              "rateLimitsByLimitId": null
            }
            """
        )

        let snapshot = CodexUsageSnapshot(response: response)

        XCTAssertNil(snapshot.shortTerm)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 55)
    }

    func testFallsBackToPrimaryAndSecondaryWhenDurationsAreMissing() throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 25},
                "secondary": {"usedPercent": 75}
              }
            }
            """
        )

        let snapshot = CodexUsageSnapshot(response: response)

        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 75)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 25)
    }

    func testRemainingPercentageIsClamped() throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": -10, "windowDurationMins": 300},
                "secondary": {"usedPercent": 150, "windowDurationMins": 10080}
              }
            }
            """
        )

        let snapshot = CodexUsageSnapshot(response: response)

        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 100)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 0)
    }

    @MainActor
    func testCancelledInitialLoadRemainsEligibleForAutomaticRetry() async {
        let provider = CancellingRateLimitProvider()
        let store = UsageStore(provider: provider)

        await store.refreshIfNeeded()
        XCTAssertFalse(store.hasAttemptedLoad)

        await store.refreshIfNeeded()
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testStorePublishesWeeklyRemainingPercentage() async throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 80, "windowDurationMins": 300},
                "secondary": {"usedPercent": 45, "windowDurationMins": 10080}
              }
            }
            """
        )
        let provider = SnapshotRateLimitProvider(
            snapshot: CodexUsageSnapshot(response: response)
        )
        let store = UsageStore(provider: provider)

        await store.refresh()

        XCTAssertEqual(store.snapshot?.weekly?.remainingPercent, 55)
    }

    @MainActor
    func testStoreRefreshesOnlyAfterSnapshotBecomesStale() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let response = try decode(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 45, "windowDurationMins": 10080}
              }
            }
            """
        )
        let provider = SnapshotRateLimitProvider(
            snapshot: CodexUsageSnapshot(
                response: response,
                fetchedAt: fetchedAt
            )
        )
        let store = UsageStore(provider: provider)

        await store.refresh()
        await store.refreshIfStale(maxAge: 60, now: fetchedAt.addingTimeInterval(59))
        var callCount = await provider.callCount
        XCTAssertEqual(callCount, 1)

        await store.refreshIfStale(maxAge: 60, now: fetchedAt.addingTimeInterval(60))
        callCount = await provider.callCount
        XCTAssertEqual(callCount, 2)
    }

    private func decode(_ json: String) throws -> AccountRateLimitsResponse {
        try JSONDecoder().decode(
            AccountRateLimitsResponse.self,
            from: Data(json.utf8)
        )
    }
}

private actor CancellingRateLimitProvider: RateLimitProviding {
    private(set) var callCount = 0

    func fetchUsage() async throws -> CodexUsageSnapshot {
        callCount += 1
        throw CancellationError()
    }
}

private actor SnapshotRateLimitProvider: RateLimitProviding {
    let snapshot: CodexUsageSnapshot
    private(set) var callCount = 0

    init(snapshot: CodexUsageSnapshot) {
        self.snapshot = snapshot
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        callCount += 1
        return snapshot
    }
}
