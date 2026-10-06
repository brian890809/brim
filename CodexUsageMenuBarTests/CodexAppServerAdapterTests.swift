import Foundation
import XCTest
@testable import CodexUsageMenuBar

final class CodexAppServerAdapterTests: XCTestCase {
    func testJSONLineBufferHandlesSplitCoalescedAndCRLFLines() throws {
        var buffer = JSONLineBuffer(maximumBytes: 100)

        try buffer.append(Data("{\"id\":".utf8))
        XCTAssertNil(try buffer.popLine())

        try buffer.append(Data("1}\r\n{\"id\":2}\n".utf8))
        XCTAssertEqual(String(data: try XCTUnwrap(buffer.popLine()), encoding: .utf8), "{\"id\":1}")
        XCTAssertEqual(String(data: try XCTUnwrap(buffer.popLine()), encoding: .utf8), "{\"id\":2}")
        XCTAssertNil(try buffer.popLine())
    }

    func testJSONLineBufferRejectsAnUnboundedFrame() throws {
        var buffer = JSONLineBuffer(maximumBytes: 4)

        XCTAssertThrowsError(try buffer.append(Data("12345".utf8))) { error in
            XCTAssertEqual(error as? CodexAppServerError, .malformedResponse)
        }
    }

    func testAdapterPerformsHandshakeAndIgnoresInterleavedMessages() async throws {
        let fixture = try ExecutableFixture(
            script: """
            #!/bin/sh
            IFS= read -r initialize
            printf '%s' "$initialize" | /usr/bin/grep -q '"method":"initialize"' || exit 41
            printf '%s' "$initialize" | /usr/bin/grep -q '"experimentalApi":false' || exit 42
            printf '%s\n' '{"method":"unrelated/notification","params":{}}'
            printf '%s\n' '{"id":1,"result":{"ok":true}}'

            IFS= read -r initialized
            printf '%s' "$initialized" | /usr/bin/grep -q '"method":"initialized"' || exit 43

            IFS= read -r rate_limits
            # JSONSerialization may legally escape forward slashes.
            printf '%s' "$rate_limits" | /usr/bin/grep -q 'account.*rateLimits.*read' || exit 44
            printf '%s\n' '{"id":999,"result":{"ignored":true}}'
            printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":2000}}}}'
            """
        )
        defer { fixture.remove() }

        let resolver = CodexExecutableResolver(
            explicitURL: fixture.url,
            codexApplicationURL: nil,
            standardApplicationURLs: [],
            pathEntries: []
        )
        let adapter = CodexAppServerAdapter(resolver: resolver, timeout: 10)

        let snapshot = try await adapter.fetchUsage()

        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 80)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 40)
        XCTAssertEqual(snapshot.shortTerm?.resetsAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 2000))
    }

    func testAdapterAddsLauncherDirectoryToPath() async throws {
        let fixture = try RuntimeBackedExecutableFixture(
            runtimeScript: Self.successfulServerScript
        )
        defer { fixture.remove() }

        let resolver = CodexExecutableResolver(
            explicitURL: fixture.launcherURL,
            codexApplicationURL: nil,
            standardApplicationURLs: [],
            pathEntries: []
        )
        let adapter = CodexAppServerAdapter(resolver: resolver, timeout: 2)

        let snapshot = try await adapter.fetchUsage()

        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 80)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 40)
    }

    func testAdapterReportsLauncherExitStatusWhenConnectionCloses() async {
        let fixture: ExecutableFixture
        do {
            fixture = try ExecutableFixture(
                script: """
                #!/bin/sh
                exec 1>&-
                /bin/sleep 0.1
                exit 73
                """
            )
        } catch {
            return XCTFail("Could not create executable fixture: \(error)")
        }
        defer { fixture.remove() }

        let resolver = CodexExecutableResolver(
            explicitURL: fixture.url,
            codexApplicationURL: nil,
            standardApplicationURLs: [],
            pathEntries: []
        )
        let adapter = CodexAppServerAdapter(resolver: resolver, timeout: 2)

        do {
            _ = try await adapter.fetchUsage()
            XCTFail("Expected the launcher to exit before replying")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .processExited(status: 73))
        }
    }

    func testLiveInstalledCodexWhenRequested() async throws {
        let resolver = await MainActor.run {
            CodexExecutableResolver.live()
        }
        let adapter = CodexAppServerAdapter(resolver: resolver, timeout: 20)

        let snapshot = try await adapter.fetchUsage()
        let windows = [snapshot.shortTerm, snapshot.weekly].compactMap { $0 }

        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { (0...100).contains($0.remainingPercent) })
    }

    private static let successfulServerScript = """
    #!/bin/sh
    IFS= read -r initialize
    printf '%s' "$initialize" | /usr/bin/grep -q '"method":"initialize"' || exit 41
    printf '%s\n' '{"id":1,"result":{"ok":true}}'

    IFS= read -r initialized
    printf '%s' "$initialized" | /usr/bin/grep -q '"method":"initialized"' || exit 42

    IFS= read -r rate_limits
    printf '%s' "$rate_limits" | /usr/bin/grep -q 'account.*rateLimits.*read' || exit 43
    printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":2000}}}}'
    """
}

private struct ExecutableFixture {
    let directoryURL: URL
    let url: URL

    init(script: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        url = directoryURL.appendingPathComponent("fake-codex")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct RuntimeBackedExecutableFixture {
    let directoryURL: URL
    let launcherURL: URL

    init(runtimeScript: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let runtimeName = "codex-test-runtime-\(UUID().uuidString)"
        let runtimeURL = directoryURL.appendingPathComponent(runtimeName)
        try Data(runtimeScript.utf8).write(to: runtimeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeURL.path
        )

        launcherURL = directoryURL.appendingPathComponent("fake-codex")
        try Data("#!/usr/bin/env \(runtimeName)\n".utf8).write(to: launcherURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
