import AppKit
import Combine
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

    func testCreditsComeFromPreferredCodexBucketWithDecimalPrecision() throws {
        let response = try decode("""
        {
          "rateLimits": {"credits": {"hasCredits": true, "unlimited": false, "balance": "999"}},
          "rateLimitsByLimitId": {
            "codex": {
              "primary": {"usedPercent": 100, "windowDurationMins": 10080},
              "credits": {"hasCredits": true, "unlimited": false, "balance": "12345.6789000000"}
            }
          }
        }
        """)
        let snapshot = CodexUsageSnapshot(response: response)
        XCTAssertEqual(snapshot.credits?.balance, Decimal(string: "12345.6789"))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 0)
        XCTAssertNil(snapshot.shortTerm)
    }

    func testMissingAndMalformedCreditsKeepAllowanceAvailableWithoutInventingBalance() throws {
        for creditField in ["", ",\"credits\":null", ",\"credits\":{}", ",\"credits\":42",
                            #", "credits":{"hasCredits":true,"unlimited":false,"balance":null}"#,
                            #", "credits":{"hasCredits":true,"unlimited":false,"balance":"12oops"}"#,
                            #", "credits":{"hasCredits":true,"unlimited":false,"balance":"12\n"}"#,
                            #", "credits":{"hasCredits":true,"unlimited":false,"balance":"NaN"}"#,
                            #", "credits":{"hasCredits":true,"unlimited":false,"balance":12}"#] {
            let response = try decode("""
            {"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080}\(creditField)}}
            """)
            let snapshot = CodexUsageSnapshot(response: response)
            XCTAssertEqual(snapshot.weekly?.remainingPercent, 0, creditField)
            XCTAssertNil(snapshot.credits?.formattedBalance(), creditField)
        }
    }

    func testMissingPreferredBucketCreditsDoNotBorrowAnotherBucketsBalance() throws {
        let response = try decode("""
        {
          "rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"999"}},
          "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100,"windowDurationMins":10080}}}
        }
        """)
        XCTAssertNil(CodexUsageSnapshot(response: response).credits)
    }

    func testZeroAndUnlimitedCreditsAreDistinctFromUnknown() throws {
        for (creditJSON, expected) in [
            (#"{"hasCredits":false,"unlimited":false,"balance":"0"}"#, "0"),
            (#"{"hasCredits":true,"unlimited":true,"balance":null}"#, "Unlimited"),
            (#"{"hasCredits":false,"unlimited":false,"balance":null}"#, nil)
        ] {
            let response = try decode("{\"rateLimits\":{\"credits\":\(creditJSON)}}")
            let credits = CodexUsageSnapshot(response: response).credits
            XCTAssertEqual(credits?.formattedBalance(), expected)
        }
    }

    func testNegativeCreditBalanceReportedByCodexIsPreserved() throws {
        let response = try decode("""
        {"rateLimits":{
          "primary":{"usedPercent":100,"windowDurationMins":10080},
          "credits":{"hasCredits":false,"unlimited":false,"balance":"-12.345"}
        }}
        """)
        let snapshot = CodexUsageSnapshot(response: response)
        XCTAssertEqual(snapshot.credits?.balance, Decimal(string: "-12.345"))
        XCTAssertEqual(snapshot.credits?.formattedBalance(locale: Locale(identifier: "en_US")), "-12.35")
    }

    func testCreditFormattingDoesNotOverstateBalanceOrHideSmallPositiveValues() {
        let locale = Locale(identifier: "en_US")
        for (raw, full, compact) in [
            ("12345.6789", "12,345.67", "12.3k"),
            ("999.999", "999.99", "999"),
            ("999999.99", "999,999.99", "999k"),
            ("1200000", "1,200,000", "1.2M"),
            ("1200000000", "1,200,000,000", "1.2B"),
            ("0.001", "<0.01", "<0.01"),
            ("-0.001", "-0.01", "-0.01"),
            ("-12345.6789", "-12,345.68", "-12.4k"),
            ("0", "0", "0")
        ] {
            let credits = CodexCredits(hasCredits: true, unlimited: false, balance: Decimal(string: raw))
            XCTAssertEqual(credits.formattedBalance(locale: locale), full)
            XCTAssertEqual(credits.formattedBalance(compact: true, locale: locale), compact)
        }
        let credits = CodexCredits(hasCredits: true, unlimited: false, balance: Decimal(string: "12345.67"))
        XCTAssertEqual(credits.formattedBalance(locale: Locale(identifier: "de_DE")), "12.345,67")
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

final class CombinedUsageUpdateTests: XCTestCase {
    func testSharedTimestampWaitsForBothProvidersAndUsesOlderReading() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 1100)
        XCTAssertNil(CombinedUsageUpdate(codexUpdatedAt: later, claudeUpdatedAt: nil).updatedAt)
        XCTAssertEqual(CombinedUsageUpdate(codexUpdatedAt: later, claudeUpdatedAt: earlier).updatedAt, earlier)
        XCTAssertEqual(CombinedUsageUpdate(codexUpdatedAt: earlier, claudeUpdatedAt: later).updatedAt, earlier)
        XCTAssertEqual(CombinedUsageUpdate(codexUpdatedAt: later, claudeUpdatedAt: later).updatedAt, later)
    }

    func testPartialRefreshDoesNotAdvertiseNewerTimeAsFullyUpdated() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 1100)
        let status = CombinedUsageUpdate(codexUpdatedAt: later, claudeUpdatedAt: earlier, hasError: true)
        XCTAssertEqual(status.updatedAt, earlier)
        XCTAssertTrue(status.isIncomplete)
        XCTAssertEqual(CombinedUsageUpdate(codexUpdatedAt: later, claudeUpdatedAt: nil).label, "Refresh incomplete")
        XCTAssertEqual(CombinedUsageUpdate(codexUpdatedAt: nil, claudeUpdatedAt: nil, hasError: true).label,
                       "Refresh incomplete")
    }

    func testInitialAndInFlightRefreshStatesAreDistinct() {
        let pending = CombinedUsageUpdate(codexUpdatedAt: nil, claudeUpdatedAt: nil)
        XCTAssertEqual(pending.label, "Not updated yet")
        XCTAssertFalse(pending.isIncomplete)
        let refreshing = CombinedUsageUpdate(codexUpdatedAt: Date(), claudeUpdatedAt: nil, isRefreshing: true)
        XCTAssertEqual(refreshing.label, "Refreshing…")
    }
}

final class UsageAutoRefreshControllerTests: XCTestCase {
    @MainActor
    func testTicksRefreshOnlyWhileAutomaticRefreshIsEnabled() {
        let ticks = PassthroughSubject<Date, Never>()
        var refreshCount = 0
        let controller = UsageAutoRefreshController(
            timerPublisher: { _ in ticks.eraseToAnyPublisher() },
            onRefresh: { refreshCount += 1 }
        )

        ticks.send(Date())
        XCTAssertEqual(refreshCount, 0)

        controller.setEnabled(true)
        ticks.send(Date())
        XCTAssertEqual(refreshCount, 1)

        controller.setEnabled(false)
        ticks.send(Date())
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testEnabledAutomaticRefreshUsesFiveMinuteInterval() {
        var scheduledInterval: TimeInterval?
        let controller = UsageAutoRefreshController(
            timerPublisher: { interval in
                scheduledInterval = interval
                return Empty().eraseToAnyPublisher()
            },
            onRefresh: {}
        )

        controller.setEnabled(true)

        XCTAssertEqual(scheduledInterval, 5 * 60)
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
