import Foundation
import XCTest
@testable import CodexUsageMenuBar

final class ClaudeUsageSnapshotTests: XCTestCase {
    func testDirectUsageDecodesISOResetAndIgnoresOtherAccountData() async throws {
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { _ in Self.credentials },
            transport: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
                return Self.response(request, status: 200, body: """
                {"five_hour":{"utilization":23.5,"resets_at":"2099-01-01T00:00:00.123Z"},
                 "seven_day":{"utilization":77},"account":"private-account"}
                """)
            }
        )
        let snapshot = try await provider.fetchUsage(allowInteraction: false)
        XCTAssertEqual(snapshot.remainingPercent, 77)
        XCTAssertNotNil(snapshot.resetsAt)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("private-account"))
    }

    func testExpiredClaudeCredentialDoesNotMakeNetworkRequest() async {
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { _ in Data("""
            {"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":1,"scopes":["user:profile"]}}
            """.utf8) },
            transport: { request in
                XCTFail("An expired credential must not be sent")
                return Self.response(request, status: 200, body: "{}")
            }
        )
        do {
            _ = try await provider.fetchUsage(allowInteraction: false)
            XCTFail("Expected sign-in guidance")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageAPIError, .signInRequired)
        }
    }

    func testDirectUsageRedactsHTTPErrorBodyAndHonorsRateLimit() async {
        let calls = ClaudeRequestCounter()
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { _ in Self.credentials },
            transport: { request in
                await calls.increment()
                return Self.response(request, status: 429, body: "fixture-token private-server-detail")
            }
        )
        for _ in 0..<2 {
            do {
                _ = try await provider.fetchUsage(allowInteraction: false)
                XCTFail("Expected rate limiting")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageAPIError, .rateLimited)
                XCTAssertFalse(error.localizedDescription.contains("fixture-token"))
                XCTAssertFalse(error.localizedDescription.contains("private-server-detail"))
            }
        }
        let count = await calls.value
        XCTAssertEqual(count, 1, "Retry-After must prevent another request even for manual refresh")
    }

    func testHTTPAuthenticationAndServerErrorsNeverSurfaceResponseBodies() async {
        for (status, expected) in [(401, ClaudeUsageAPIError.signInRequired), (403, .missingScope), (503, .server(503))] {
            let provider = ClaudeUsageAPIAdapter(
                credentialReader: { _ in Self.credentials },
                transport: { request in Self.response(request, status: status, body: "fixture-token") }
            )
            do {
                _ = try await provider.fetchUsage(allowInteraction: false)
                XCTFail("Expected HTTP error")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageAPIError, expected)
                XCTAssertFalse(error.localizedDescription.contains("fixture-token"))
            }
        }
    }

    func testMissingProfileScopeDoesNotSendToken() async {
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { _ in Data("""
            {"claudeAiOauth":{"accessToken":"fixture-token","scopes":["user:inference"]}}
            """.utf8) },
            transport: { request in
                XCTFail("Inference-only credentials can't fetch usage")
                return Self.response(request, status: 200, body: "{}")
            }
        )
        do {
            _ = try await provider.fetchUsage(allowInteraction: false)
            XCTFail("Expected missing scope")
        } catch { XCTAssertEqual(error as? ClaudeUsageAPIError, .missingScope) }
    }

    @MainActor
    func testFailedAutomaticCheckIsThrottledAndManualRefreshCanRequestAccess() async {
        let calls = ClaudeRequestCounter()
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { _ in Self.credentials },
            transport: { request in
                await calls.increment()
                return Self.response(request, status: 503, body: "fixture-token")
            }
        )
        let store = ClaudeUsageStore(monitor: false, provider: provider)
        await store.refreshIfStale()
        await store.refreshIfStale()
        var count = await calls.value
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isRefreshing)
        await store.refreshFromAccount(allowInteraction: true)
        count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testDirectUsageRejectsAbsentWindowInsteadOfInventingFullAllowance() async {
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { _ in Self.credentials },
            transport: { request in Self.response(request, status: 200, body: "{\"five_hour\":null}") }
        )
        do {
            _ = try await provider.fetchUsage(allowInteraction: false)
            XCTFail("Expected unavailable window")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageAPIError, .noWindow)
        }
    }

    @MainActor
    func testStoreFetchesIndependentlyAndDoesNotReplaceLiveDataWithOldCapture() async throws {
        let provider = ClaudeUsageAPIAdapter(
            credentialReader: { interaction in
                XCTAssertTrue(interaction)
                return Self.credentials
            },
            transport: { request in Self.response(request, status: 200, body: """
            {"five_hour":{"utilization":40,"resets_at":"2099-01-01T00:00:00Z"}}
            """) }
        )
        let store = ClaudeUsageStore(monitor: false, provider: provider)
        await store.refreshFromAccount(allowInteraction: true)
        XCTAssertEqual(store.snapshot?.remainingPercent, 60)
        store.refresh()
        XCTAssertEqual(store.snapshot?.remainingPercent, 60)
        XCTAssertNil(store.errorMessage)
    }

    private static var credentials: Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":4102444800000,"scopes":["user:profile"]}}
        """.utf8)
    }

    private static func response(_ request: URLRequest, status: Int, body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Retry-After":"300"])!)
    }

    func testDecodesOfficialFiveHourRateLimitFields() throws {
        let snapshot = try decode(
            """
            {
              "version": 2,
              "updatedAt": 1738425000,
              "rateLimits": {
                "fiveHour": {
                  "usedPercentage": 23.5,
                  "resetsAt": 1738425600
                }
              }
            }
            """
        )

        XCTAssertEqual(snapshot.remainingPercent, 77)
        XCTAssertEqual(
            snapshot.resetsAt,
            Date(timeIntervalSince1970: 1_738_425_600)
        )
        XCTAssertEqual(
            snapshot.updatedAt,
            Date(timeIntervalSince1970: 1_738_425_000)
        )
        XCTAssertFalse(
            snapshot.isExpired(
                at: Date(timeIntervalSince1970: 1_738_425_599)
            )
        )
        XCTAssertTrue(
            snapshot.isExpired(
                at: Date(timeIntervalSince1970: 1_738_425_600)
            )
        )
    }

    func testRemainingPercentageClampsAndMissingWindowStaysUnavailable() throws {
        let overused = try decode(
            """
            {
              "version": 2,
              "updatedAt": 1738425000,
              "rateLimits": {
                "fiveHour": {
                  "usedPercentage": 110,
                  "resetsAt": null
                }
              }
            }
            """
        )
        let underused = try decode(
            """
            {
              "version": 2,
              "updatedAt": 1738425000,
              "rateLimits": {
                "fiveHour": {
                  "usedPercentage": -10,
                  "resetsAt": null
                }
              }
            }
            """
        )
        let missing = try decode(
            """
            {
              "version": 2,
              "updatedAt": 1738425000,
              "rateLimits": {
                "fiveHour": null
              }
            }
            """
        )

        XCTAssertEqual(overused.remainingPercent, 0)
        XCTAssertEqual(underused.remainingPercent, 100)
        XCTAssertNil(missing.remainingPercent)
        XCTAssertNil(missing.resetsAt)
        XCTAssertTrue(missing.isExpired())
    }

    @MainActor
    func testStoreDoesNotPresentAnExpiredCachedWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("claude-usage.json")
        let now = Date(timeIntervalSince1970: 1_738_425_600)
        try Data(
            """
            {
              "version": 2,
              "updatedAt": 1738425000,
              "rateLimits": {
                "fiveHour": {
                  "usedPercentage": 23.5,
                  "resetsAt": 1738425599
                }
              }
            }
            """.utf8
        ).write(to: cacheURL)

        let store = ClaudeUsageStore(cacheURL: cacheURL, monitor: false)
        store.refresh(now: now)

        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStoreRejectsACachedWindowWithoutAResetTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheURL = directory.appendingPathComponent("claude-usage.json")
        try Data(
            """
            {
              "version": 2,
              "updatedAt": 1738425000,
              "rateLimits": {
                "fiveHour": {
                  "usedPercentage": 23.5,
                  "resetsAt": null
                }
              }
            }
            """.utf8
        ).write(to: cacheURL)

        let store = ClaudeUsageStore(cacheURL: cacheURL, monitor: false)

        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.errorMessage)
    }

    func testCaptureKeepsOnlyFiveHourUsageAndPreservesLastValidSnapshot() throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexUsageMenuBar/Resources/ClaudeContextCapture.sh")

        try runCapture(
            scriptURL: scriptURL,
            homeURL: temporaryHome,
            input: """
            {
              "session_id": "private-session",
              "transcript_path": "/private/transcript.jsonl",
              "workspace": {"project_dir": "/private/project"},
              "context_window": {"remaining_percentage": 36},
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 23.5,
                  "resets_at": 1738425600
                }
              }
            }
            """
        )

        let cacheURL = temporaryHome
            .appendingPathComponent("Library/Caches/com.bchen.CodexUsageMenuBar")
            .appendingPathComponent("claude-usage.json")
        let firstData = try Data(contentsOf: cacheURL)
        let firstText = String(decoding: firstData, as: UTF8.self)
        let snapshot = try decode(firstText)

        XCTAssertEqual(snapshot.remainingPercent, 77)
        XCTAssertFalse(firstText.contains("session"))
        XCTAssertFalse(firstText.contains("transcript"))
        XCTAssertFalse(firstText.contains("workspace"))
        XCTAssertFalse(firstText.contains("context"))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: cacheURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        try runCapture(
            scriptURL: scriptURL,
            homeURL: temporaryHome,
            input: """
            {
              "context_window": {"remaining_percentage": 99},
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 1,
                  "resets_at": null
                }
              }
            }
            """
        )

        XCTAssertEqual(try Data(contentsOf: cacheURL), firstData)
    }

    private func decode(_ json: String) throws -> ClaudeUsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(
            ClaudeUsageSnapshot.self,
            from: Data(json.utf8)
        )
    }

    private func runCapture(
        scriptURL: URL,
        homeURL: URL,
        input: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private actor ClaudeRequestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
