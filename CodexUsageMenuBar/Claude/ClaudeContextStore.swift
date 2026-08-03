import Combine
import Foundation

@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var errorMessage: String?

    private let cacheURL: URL
    private var timerCancellable: AnyCancellable?

    init(cacheURL: URL? = nil, monitor: Bool = true) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
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
}
