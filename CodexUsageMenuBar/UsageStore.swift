import AppKit
import Combine
import Foundation

@MainActor
final class UsageAutoRefreshController {
    static let interval: TimeInterval = 5 * 60

    typealias TimerPublisher = (TimeInterval) -> AnyPublisher<Date, Never>

    private let timerPublisher: TimerPublisher
    private let onRefresh: @MainActor () -> Void
    private var timerCancellable: AnyCancellable?
    private var isEnabled = false

    init(
        timerPublisher: @escaping TimerPublisher = { interval in
            Timer.publish(every: interval, on: .main, in: .common)
                .autoconnect()
                .eraseToAnyPublisher()
        },
        onRefresh: @escaping @MainActor () -> Void
    ) {
        self.timerPublisher = timerPublisher
        self.onRefresh = onRefresh
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        timerCancellable?.cancel()
        timerCancellable = nil

        guard enabled else { return }
        timerCancellable = timerPublisher(Self.interval)
            .sink { [weak self] _ in
                self?.onRefresh()
            }
    }
}

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
