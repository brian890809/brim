import Foundation
import XCTest
import WebKit
@testable import CodexUsageMenuBar

final class ClaudeUsageSnapshotTests: XCTestCase {
    @MainActor
    func testBundledUsageScriptRunsInAnIsolatedWebKitWorld() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        let loaded = expectation(description: "Synthetic page loaded")
        let navigation = SyntheticClaudeNavigation { loaded.fulfill() }
        view.navigationDelegate = navigation
        view.loadHTMLString("<html><body>Offline fixture</body></html>", baseURL: URL(string: "https://claude.ai"))
        await fulfillment(of: [loaded], timeout: 10)
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "ClaudeWebUsage", withExtension: "js"))
        let script = try String(contentsOf: resource, encoding: .utf8)
        let fixture = """
        globalThis.fetch = async (path, options) => ({
          status: 200, ok: true, headers: {get: () => 'application/json'},
          json: async () => path === '/api/organizations'
            ? [{uuid: '12345678-1234-1234-1234-123456789abc', name: 'Fixture'}]
            : {five_hour: {utilization: 25, resets_at: '2099-01-01T00:00:00Z'}, private: 'excluded'}
        });
        """
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(fixture + script, arguments: ["organizationID": ""],
                in: nil, in: .defaultClient) { result in continuation.resume(with: result) }
        }
        let payload = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "usage")
        XCTAssertEqual(payload["utilization"] as? Double, 25)
        XCTAssertNil(payload["private"])
    }
    @MainActor
    func testAppOwnedConnectionFetchesWithoutClaudeCodeCredentials() async throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
             "utilization": 25.0, "resetsAt": "2099-01-01T00:00:00Z"]
        })
        let result = try await adapter.fetchUsage(allowInteraction: false)
        XCTAssertEqual(result.remainingPercent, 75)
        XCTAssertNotNil(result.resetsAt)
    }

    @MainActor
    func testNotStartedSessionRemainsVisibleUntilItNeedsAFreshReading() async throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
             "utilization": 0.0, "resetsAt": NSNull(), "state": "notStarted"]
        })
        let store = ClaudeUsageStore(monitor: false, provider: adapter)
        await store.refreshFromAccount()
        let result = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(result.remainingPercent, 100)
        XCTAssertNil(result.resetsAt)
        XCTAssertTrue(result.isAwaitingFirstMessage)
        XCTAssertNil(store.errorMessage)
        store.refresh(now: result.updatedAt.addingTimeInterval(299))
        XCTAssertNotNil(store.snapshot)
        store.refresh(now: result.updatedAt.addingTimeInterval(300))
        XCTAssertNil(store.snapshot)
    }

    @MainActor
    func testStartingASessionReplacesTheIdleReadingWithItsRealReset() async throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        var started = false
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            if started {
                return ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
                        "utilization": 25.0, "resetsAt": "2099-01-01T00:00:00Z"]
            }
            return ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
                    "utilization": 0.0, "resetsAt": NSNull(), "state": "notStarted"]
        })
        let store = ClaudeUsageStore(monitor: false, provider: adapter)
        await store.refreshFromAccount()
        XCTAssertTrue(try XCTUnwrap(store.snapshot).isAwaitingFirstMessage)
        started = true
        await store.refreshFromAccount()
        XCTAssertEqual(store.snapshot?.remainingPercent, 75)
        XCTAssertFalse(try XCTUnwrap(store.snapshot).isAwaitingFirstMessage)
        XCTAssertNotNil(store.snapshot?.resetsAt)
    }

    @MainActor
    func testInvalidIdlePayloadsCannotBecomeFullAllowance() async {
        for extra: [String: Any] in [
            ["utilization": 25.0, "resetsAt": NSNull(), "state": "notStarted"],
            ["utilization": 0.0, "state": "notStarted"],
            ["utilization": 0.0, "resetsAt": NSNull()],
            ["utilization": 0.0, "resetsAt": "2099-01-01T00:00:00Z", "state": "notStarted"]
        ] {
            let preferences = UserDefaults(suiteName: UUID().uuidString)!
            preferences.set(true, forKey: "claudeWebConnectionEnabled")
            let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
                ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc"]
                    .merging(extra) { _, new in new }
            })
            do { _ = try await adapter.fetchUsage(allowInteraction: false); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? ClaudeUsageAPIError, .invalidResponse) }
        }
    }

    func testLegacyZeroWithoutResetIsNotMistakenForAnObservedIdleSession() {
        let snapshot = ClaudeUsageSnapshot(version: 2, updatedAt: Date(),
            rateLimits: .init(fiveHour: .init(usedPercentage: 0, resetsAt: nil)))
        XCTAssertFalse(snapshot.isAwaitingFirstMessage)
        XCTAssertTrue(snapshot.isExpired())
    }

    @MainActor
    func testUnconnectedAppNeverExecutesAuthenticatedBrowserRequests() async {
        let adapter = ClaudeWebUsageAdapter(defaults: UserDefaults(suiteName: UUID().uuidString)!, evaluate: {
            XCTFail("Background and manual Refresh must wait for explicit Connect")
            return ["kind": "usage"]
        })
        for interactive in [false, true] {
            do { _ = try await adapter.fetchUsage(allowInteraction: interactive); XCTFail("Expected connection requirement") }
            catch { XCTAssertEqual(error as? ClaudeUsageAPIError, .signInRequired) }
        }
    }

    @MainActor
    func testWebRateLimitPreventsRepeatedBrowserRequests() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        var calls = 0
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            calls += 1
            return ["kind": "rateLimited", "retryAfter": 120.0]
        })
        for _ in 0..<2 {
            do { _ = try await adapter.fetchUsage(allowInteraction: false); XCTFail("Expected rate limiting") }
            catch { XCTAssertEqual(error as? ClaudeUsageAPIError, .rateLimited) }
        }
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testDisconnectRevokesBrowserRequestsAndClearsVisibleUsage() async throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        var calls = 0
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            calls += 1
            return ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
                    "utilization": 25.0, "resetsAt": "2099-01-01T00:00:00Z"]
        })
        let store = ClaudeUsageStore(monitor: false, provider: adapter)
        await store.refreshFromAccount()
        XCTAssertEqual(store.snapshot?.remainingPercent, 75)
        await adapter.disconnect()
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(preferences.bool(forKey: "claudeWebConnectionEnabled"))
        XCTAssertNil(preferences.string(forKey: "claudeWebOrganizationID"))
        await store.refreshFromAccount(allowInteraction: true)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testDisconnectDiscardsAnInFlightResponseFromTheOldAccount() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        let started = expectation(description: "Browser request began")
        var pending: CheckedContinuation<[String: Any], Never>?
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        })
        let store = ClaudeUsageStore(monitor: false, provider: adapter)
        let request = Task { await store.refreshFromAccount() }
        await fulfillment(of: [started], timeout: 2)
        await adapter.disconnect()
        pending?.resume(returning: ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
                                   "utilization": 25.0, "resetsAt": "2099-01-01T00:00:00Z"])
        await request.value
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testRejectedSignInClearsUsageFromThePreviousAccount() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        var calls = 0
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            calls += 1
            if calls > 1 { return ["kind": "signIn"] }
            return ["kind": "usage", "organizationID": "12345678-1234-1234-1234-123456789abc",
                    "utilization": 25.0, "resetsAt": "2099-01-01T00:00:00Z"]
        })
        let store = ClaudeUsageStore(monitor: false, provider: adapter)
        await store.refreshFromAccount()
        XCTAssertEqual(store.snapshot?.remainingPercent, 75)
        await store.refreshFromAccount()
        XCTAssertNil(store.snapshot)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testBrowserErrorsNeverExposeRawCredentialLikeDetails() async {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "claudeWebConnectionEnabled")
        let adapter = ClaudeWebUsageAdapter(defaults: preferences, evaluate: {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "sessionKey=private-fixture"])
        })
        do { _ = try await adapter.fetchUsage(allowInteraction: false); XCTFail("Expected network failure") }
        catch {
            XCTAssertEqual(error as? ClaudeUsageAPIError, .network)
            XCTAssertFalse(error.localizedDescription.contains("private-fixture"))
            XCTAssertFalse(adapter.statusText.contains("private-fixture"))
        }
    }

    @MainActor
    func testOnlyTheSecureClaudeOriginCanRunUsageCode() {
        XCTAssertTrue(ClaudeWebUsageAdapter.isClaudeOrigin(URL(string: "https://claude.ai/login")))
        for url in ["http://claude.ai", "https://claude.ai.evil.invalid", "https://claude.ai:8443",
                    "https://someone:fixture@claude.ai", "about:blank", "file:///tmp/example"] {
            XCTAssertFalse(ClaudeWebUsageAdapter.isClaudeOrigin(URL(string: url)), url)
        }
    }

    @MainActor
    func testDefaultStoreOffersAnAppOwnedConnection() {
        let store = ClaudeUsageStore(monitor: false)
        XCTAssertTrue(store.supportsClaudeConnection)
        XCTAssertNil(store.snapshot)
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

@MainActor
private final class SyntheticClaudeNavigation: NSObject, WKNavigationDelegate {
    let completed: () -> Void
    init(completed: @escaping () -> Void) { self.completed = completed }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Synthetic WebKit page failed to load")
        completed()
    }
}
