import Foundation

struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    struct RateLimits: Codable, Equatable, Sendable {
        let fiveHour: UsageWindow?
    }

    struct UsageWindow: Codable, Equatable, Sendable {
        let usedPercentage: Double?
        let resetsAt: Date?
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

    func isExpired(at date: Date = Date()) -> Bool {
        guard let resetsAt else { return true }
        return resetsAt <= date
    }
}
