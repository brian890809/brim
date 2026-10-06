import Foundation
import XCTest
@testable import CodexUsageMenuBar

final class CodexExecutableResolverTests: XCTestCase {
    func testExplicitExecutableTakesPrecedence() throws {
        let resolver = CodexExecutableResolver(
            explicitURL: URL(fileURLWithPath: "/bin/echo"),
            codexApplicationURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            standardApplicationURLs: [],
            pathEntries: [URL(fileURLWithPath: "/usr/bin", isDirectory: true)]
        )

        XCTAssertEqual(
            try resolver.resolve(),
            URL(fileURLWithPath: "/bin/echo").resolvingSymlinksInPath()
        )
    }

    func testMissingCandidatesProduceAnActionableError() {
        let resolver = CodexExecutableResolver(
            explicitURL: URL(fileURLWithPath: "/definitely/not/a/codex/binary"),
            codexApplicationURL: nil,
            standardApplicationURLs: [],
            pathEntries: []
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            XCTAssertEqual(error as? CodexAppServerError, .executableNotFound)
        }
    }

    func testCurrentChatGPTBundlePrefersNestedNativeCodexExecutable() throws {
        let fixture = try CodexApplicationFixture()
        defer { fixture.remove() }

        let resolver = CodexExecutableResolver(
            explicitURL: nil,
            codexApplicationURL: fixture.applicationURL,
            standardApplicationURLs: [],
            pathEntries: []
        )

        XCTAssertEqual(
            try resolver.resolve(),
            fixture.nativeExecutableURL.resolvingSymlinksInPath()
        )
    }
}

private struct CodexApplicationFixture {
    let rootURL: URL
    let applicationURL: URL
    let nativeExecutableURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        applicationURL = rootURL.appendingPathComponent("ChatGPT.app", isDirectory: true)
        nativeExecutableURL = applicationURL
            .appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

        try FileManager.default.createDirectory(
            at: nativeExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nativeExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nativeExecutableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
