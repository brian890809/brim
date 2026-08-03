import Foundation
import XCTest
@testable import CodexUsageMenuBar

final class ClaudeUsageSnapshotTests: XCTestCase {
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
