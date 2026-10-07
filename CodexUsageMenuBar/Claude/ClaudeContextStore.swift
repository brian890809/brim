import Combine
import Foundation

@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let cacheURL: URL
    private var timerCancellable: AnyCancellable?
    private let provider: (any ClaudeUsageProviding)?
    private var lastAttemptAt: Date?

    init(cacheURL: URL? = nil, monitor: Bool = true, provider: (any ClaudeUsageProviding)? = nil) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        // Explicit cache paths are used for offline previews and capture tests.
        self.provider = provider ?? (cacheURL == nil ? ClaudeUsageAPIAdapter() : nil)
        refresh()

        if monitor {
            timerCancellable = Timer.publish(
                every: 1,
                on: .main,
                in: .common
            )
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
        }
    }

    static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(
                "com.bchen.CodexUsageMenuBar",
                isDirectory: true
            )
            .appendingPathComponent("claude-usage.json")
    }

    func refresh(now: Date = Date()) {
        if provider != nil {
            if snapshot?.isExpired(at: now) == true { snapshot = nil }
            return
        }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let latest = try decoder.decode(
                ClaudeUsageSnapshot.self,
                from: data
            )

            guard !latest.isExpired(at: now) else {
                snapshot = nil
                errorMessage = nil
                return
            }

            if latest != snapshot {
                snapshot = latest
            }
            errorMessage = nil
        } catch CocoaError.fileReadNoSuchFile {
            snapshot = nil
            errorMessage = nil
        } catch {
            errorMessage = "Claude usage data could not be read."
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 60, now: Date = Date()) async {
        guard provider != nil else { refresh(now: now); return }
        refresh(now: now)
        let lastCheck = lastAttemptAt ?? snapshot?.updatedAt
        if let lastCheck, now.timeIntervalSince(lastCheck) < maxAge { return }
        await refreshFromAccount()
    }

    func refreshFromAccount(allowInteraction: Bool = false) async {
        guard let provider else { refresh(); return }
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        lastAttemptAt = Date()
        defer { isRefreshing = false }
        do {
            snapshot = try await provider.fetchUsage(allowInteraction: allowInteraction)
        } catch is CancellationError {
            lastAttemptAt = nil
        } catch {
            refresh()
            errorMessage = (error as? ClaudeUsageAPIError)?.errorDescription
                ?? "Claude usage could not be loaded."
        }
    }
}
