import Foundation

enum ClaudeUsagePeriod: String, CaseIterable, Identifiable {
    case fiveHour, weekly, fable

    var id: Self { self }
    var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        case .fable: "Fable"
        }
    }
    var allowanceTitle: String {
        switch self {
        case .fiveHour: "5-hour allowance"
        case .weekly: "Weekly allowance"
        case .fable: "Fable weekly allowance"
        }
    }
}

struct ClaudeUsageSnapshot: Codable, Equatable, Sendable {
    struct RateLimits: Codable, Equatable, Sendable {
        let fiveHour: UsageWindow?
        let weekly: UsageWindow?
        let fable: UsageWindow?

        init(fiveHour: UsageWindow?, weekly: UsageWindow? = nil, fable: UsageWindow? = nil) {
            self.fiveHour = fiveHour
            self.weekly = weekly
            self.fable = fable
        }

        subscript(period: ClaudeUsagePeriod) -> UsageWindow? {
            switch period {
            case .fiveHour: fiveHour
            case .weekly: weekly
            case .fable: fable
            }
        }
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

        var remainingPercent: Int? {
            guard let usedPercentage, usedPercentage.isFinite else { return nil }
            return Int(min(100, max(0, (100 - usedPercentage).rounded())))
        }

        var isAwaitingFirstMessage: Bool {
            state == .notStarted && usedPercentage == 0 && resetsAt == nil
        }

        func isExpired(updatedAt: Date, at date: Date) -> Bool {
            if isAwaitingFirstMessage { return date.timeIntervalSince(updatedAt) >= 300 }
            guard let resetsAt else { return true }
            return resetsAt <= date
        }
    }

    let version: Int
    let updatedAt: Date
    let rateLimits: RateLimits

    var remainingPercent: Int? {
        rateLimits.fiveHour?.remainingPercent
    }

    var resetsAt: Date? {
        rateLimits.fiveHour?.resetsAt
    }

    var isAwaitingFirstMessage: Bool {
        rateLimits.fiveHour?.isAwaitingFirstMessage == true
    }

    func isExpired(at date: Date = Date()) -> Bool {
        ClaudeUsagePeriod.allCases.allSatisfy { window(for: $0, at: date) == nil }
    }

    func window(for period: ClaudeUsagePeriod, at date: Date = Date()) -> UsageWindow? {
        guard let window = rateLimits[period],
              !window.isExpired(updatedAt: updatedAt, at: date) else { return nil }
        return window
    }

    /// A five-hour reset must not discard a still-valid weekly allowance.
    func removingExpiredWindows(at date: Date = Date()) -> Self? {
        guard !isExpired(at: date) else { return nil }
        return .init(version: version, updatedAt: updatedAt, rateLimits: .init(
            fiveHour: window(for: .fiveHour, at: date),
            weekly: window(for: .weekly, at: date),
            fable: window(for: .fable, at: date)
        ))
    }
}
