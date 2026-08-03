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
}
