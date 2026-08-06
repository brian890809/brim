import Foundation

struct CodexUsageWindow: Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Date?

    var remainingPercent: Int {
        min(100, max(0, 100 - usedPercent))
    }
}
struct CodexUsageSnapshot: Equatable, Sendable {
    let shortTerm: CodexUsageWindow?
    let weekly: CodexUsageWindow?
    let fetchedAt: Date

    init(
        shortTerm: CodexUsageWindow?,
        weekly: CodexUsageWindow?,
        fetchedAt: Date = Date()
    ) {
        self.shortTerm = shortTerm
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }

    init(response: AccountRateLimitsResponse, fetchedAt: Date = Date()) {
        let rateLimit = response.preferredCodexRateLimit
        let classified = Self.classify(
            primary: rateLimit.primary,
            secondary: rateLimit.secondary
        )

        shortTerm = classified.shortTerm.map(Self.makeUsageWindow)
        weekly = classified.weekly.map(Self.makeUsageWindow)
        self.fetchedAt = fetchedAt
    }

    private static func makeUsageWindow(_ payload: RateLimitWindowPayload) -> CodexUsageWindow {
        CodexUsageWindow(
            usedPercent: payload.usedPercent,
            windowDurationMins: payload.windowDurationMins,
            resetsAt: payload.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func classify(
        primary: RateLimitWindowPayload?,
        secondary: RateLimitWindowPayload?
    ) -> (shortTerm: RateLimitWindowPayload?, weekly: RateLimitWindowPayload?) {
        enum Source {
            case primary
            case secondary
        }

        struct Candidate {
            let source: Source
            let window: RateLimitWindowPayload
        }

        var candidates: [Candidate] = []
        if let primary {
            candidates.append(Candidate(source: .primary, window: primary))
        }
        if let secondary {
            candidates.append(Candidate(source: .secondary, window: secondary))
        }

        guard !candidates.isEmpty else {
            return (nil, nil)
        }

        var shortTermIndex: Int?
        var weeklyIndex: Int?
        let knownDurations = candidates.indices.filter {
            candidates[$0].window.windowDurationMins != nil
        }

        if knownDurations.count >= 2 {
            let ordered = knownDurations.sorted {
                candidates[$0].window.windowDurationMins! < candidates[$1].window.windowDurationMins!
            }
            let firstDuration = candidates[ordered.first!].window.windowDurationMins!
            let lastDuration = candidates[ordered.last!].window.windowDurationMins!

            if firstDuration != lastDuration {
                shortTermIndex = ordered.first
                weeklyIndex = ordered.last
            }
        }

        if weeklyIndex == nil {
            weeklyIndex = knownDurations.first {
                guard let duration = candidates[$0].window.windowDurationMins else { return false }
                return duration >= 6 * 24 * 60
            }
        }

        if shortTermIndex == nil {
            shortTermIndex = knownDurations.first {
                guard let duration = candidates[$0].window.windowDurationMins else { return false }
                return duration < 6 * 24 * 60 && $0 != weeklyIndex
            }
        }

        for index in candidates.indices where index != shortTermIndex && index != weeklyIndex {
            switch candidates[index].source {
            case .primary where shortTermIndex == nil:
                shortTermIndex = index
            case .secondary where weeklyIndex == nil:
                weeklyIndex = index
            default:
                if shortTermIndex == nil {
                    shortTermIndex = index
                } else if weeklyIndex == nil {
                    weeklyIndex = index
                }
            }
        }

        return (
            shortTermIndex.map { candidates[$0].window },
            weeklyIndex.map { candidates[$0].window }
        )
    }
}
