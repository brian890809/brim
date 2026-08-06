import Foundation

/// Launch-argument-driven dev mode that feeds fixed percentages into the
/// notch so any value can be checked without live Codex or Claude data:
///
///     CodexUsageMenuBar -PreviewCodexPercent 100 -PreviewClaudePercent 100
///
/// Each argument is independent; a provider without one keeps its live data.
struct NotchPreviewOptions {
    static let codexArgumentKey = "PreviewCodexPercent"
    static let claudeArgumentKey = "PreviewClaudePercent"

    let codexRemainingPercent: Int?
    let claudeRemainingPercent: Int?

    var isActive: Bool {
        codexRemainingPercent != nil || claudeRemainingPercent != nil
    }

    init(defaults: UserDefaults = .standard) {
        codexRemainingPercent = Self.percent(
            forKey: Self.codexArgumentKey,
            in: defaults
        )
        claudeRemainingPercent = Self.percent(
            forKey: Self.claudeArgumentKey,
            in: defaults
        )
    }

    private static func percent(
        forKey key: String,
        in defaults: UserDefaults
    ) -> Int? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return min(100, max(0, defaults.integer(forKey: key)))
    }
}

struct PreviewRateLimitProvider: RateLimitProviding {
    let remainingPercent: Int

    func fetchUsage() async throws -> CodexUsageSnapshot {
        let now = Date()
        let usedPercent = 100 - remainingPercent

        return CodexUsageSnapshot(
            shortTerm: CodexUsageWindow(
                usedPercent: usedPercent,
                windowDurationMins: 5 * 60,
                resetsAt: now.addingTimeInterval(5 * 3600)
            ),
            weekly: CodexUsageWindow(
                usedPercent: usedPercent,
                windowDurationMins: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600)
            ),
            fetchedAt: now
        )
    }
}

enum NotchPreviewMode {
    @MainActor
    static func makeWindowController(
        options: NotchPreviewOptions
    ) -> NotchWindowController {
        let usageStore = options.codexRemainingPercent.map {
            UsageStore(provider: PreviewRateLimitProvider(remainingPercent: $0))
        } ?? UsageStore()

        let claudeStore = options.claudeRemainingPercent
            .flatMap { percent -> ClaudeUsageStore? in
                guard
                    let cacheURL = try? writeClaudeCache(
                        remainingPercent: percent
                    )
                else {
                    return nil
                }
                return ClaudeUsageStore(cacheURL: cacheURL, monitor: false)
            } ?? ClaudeUsageStore()

        return NotchWindowController(
            usageStore: usageStore,
            claudeStore: claudeStore,
            presentation: NotchPresentationModel()
        )
    }

    /// Writes a synthetic Claude cache file so the preview flows through the
    /// same decode path as the real capture script.
    static func writeClaudeCache(
        remainingPercent: Int,
        now: Date = Date()
    ) throws -> URL {
        let snapshot = ClaudeUsageSnapshot(
            version: 1,
            updatedAt: now,
            rateLimits: .init(
                fiveHour: .init(
                    usedPercentage: Double(100 - remainingPercent),
                    resetsAt: now.addingTimeInterval(5 * 3600)
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexUsageMenuBarPreview",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cacheURL = directory.appendingPathComponent("claude-usage.json")
        try encoder.encode(snapshot).write(to: cacheURL)
        return cacheURL
    }
}
