import AppKit
import Foundation

struct CodexExecutableResolver: Sendable {
    private let explicitURL: URL?
    private let codexApplicationURL: URL?
    private let standardApplicationURLs: [URL]
    private let pathEntries: [URL]

    init(
        explicitURL: URL?,
        codexApplicationURL: URL?,
        standardApplicationURLs: [URL],
        pathEntries: [URL]
    ) {
        self.explicitURL = explicitURL
        self.codexApplicationURL = codexApplicationURL
        self.standardApplicationURLs = standardApplicationURLs
        self.pathEntries = pathEntries
    }

    @MainActor
    static func live() -> CodexExecutableResolver {
        let explicitURL = environmentValue(named: "CODEX_USAGE_CODEX_PATH")
            .map { URL(fileURLWithPath: $0) }
        let pathEntries = environmentValue(named: "PATH")?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) } ?? []
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)

        return CodexExecutableResolver(
            explicitURL: explicitURL,
            codexApplicationURL: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ),
            standardApplicationURLs: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
                userApplications.appendingPathComponent("ChatGPT.app", isDirectory: true),
                userApplications.appendingPathComponent("Codex.app", isDirectory: true),
            ],
            pathEntries: pathEntries + [
                URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            ]
        )
    }

    func resolve() throws -> URL {
        var candidates: [URL] = []

        if let explicitURL {
            candidates.append(explicitURL)
        }

        if let codexApplicationURL {
            candidates.append(Self.codexURL(in: codexApplicationURL))
        }

        candidates.append(contentsOf: standardApplicationURLs.map(Self.codexURL(in:)))
        candidates.append(contentsOf: pathEntries.map {
            $0.appendingPathComponent("codex", isDirectory: false)
        })

        var visitedPaths = Set<String>()
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard visitedPaths.insert(normalized.path).inserted else { continue }

            if FileManager.default.isExecutableFile(atPath: normalized.path) {
                return normalized
            }
        }

        throw CodexAppServerError.executableNotFound
    }

    private static func codexURL(in applicationURL: URL) -> URL {
        applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
    }

    private static func environmentValue(named name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }
}
