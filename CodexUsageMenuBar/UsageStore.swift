import AppKit
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasAttemptedLoad = false

    private let provider: any RateLimitProviding

    init(provider: (any RateLimitProviding)? = nil) {
        self.provider = provider ?? CodexAppServerAdapter(
            resolver: CodexExecutableResolver.live()
        )
    }

    func refreshIfNeeded() async {
        guard !hasAttemptedLoad else { return }
        await refresh()
    }

    func refreshIfStale(
        maxAge: TimeInterval = 60,
        now: Date = Date()
    ) async {
        guard !isRefreshing else { return }

        if let fetchedAt = snapshot?.fetchedAt {
            guard now.timeIntervalSince(fetchedAt) >= maxAge else { return }
        }

        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        errorMessage = nil
        defer {
            isRefreshing = false
        }

        do {
            snapshot = try await provider.fetchUsage()
            hasAttemptedLoad = true
        } catch is CancellationError {
            return
        } catch {
            hasAttemptedLoad = true
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Codex usage could not be loaded."
        }
    }

    func openCodex() {
        let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) ?? URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)

        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            errorMessage = "Codex could not be found in Applications."
            return
        }

        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.errorMessage = "Codex could not be opened."
            }
        }
    }
}
