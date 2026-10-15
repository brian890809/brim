import Foundation

struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    struct RateLimits: Codable, Equatable, Sendable {
        let fiveHour: UsageWindow?
    }

    struct UsageWindow: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case notStarted }
        let usedPercentage: Double?
        let resetsAt: Date?
        let state: State?

        init(usedPercentage: Double?, resetsAt: Date?, state: State? = nil) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
            self.state = state
        }
    }

    let version: Int
    let updatedAt: Date
    let rateLimits: RateLimits

    var remainingPercent: Int? {
        guard
            let usedPercentage = rateLimits.fiveHour?.usedPercentage,
            usedPercentage.isFinite
        else {
            return nil
        }

        let remaining = 100 - usedPercentage
        return min(100, max(0, Int(remaining.rounded())))
    }

    var resetsAt: Date? {
        rateLimits.fiveHour?.resetsAt
    }

    var isAwaitingFirstMessage: Bool {
        rateLimits.fiveHour?.state == .notStarted
            && rateLimits.fiveHour?.usedPercentage == 0 && resetsAt == nil
    }

    func isExpired(at date: Date = Date()) -> Bool {
        // Idle is an observed state, not a fabricated five-hour reset. Recheck
        // after the normal polling interval in case a session started elsewhere.
        if isAwaitingFirstMessage { return date.timeIntervalSince(updatedAt) >= 300 }
        guard let resetsAt else { return true }
        return resetsAt <= date
    }
}
