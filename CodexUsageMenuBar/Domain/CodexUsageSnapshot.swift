import Foundation

struct CodexCredits: Decodable, Equatable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Decimal?

    init(hasCredits: Bool, unlimited: Bool, balance: Decimal?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance.flatMap { !$0.isNaN ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case hasCredits, unlimited, balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawBalance = try? container.decodeIfPresent(String.self, forKey: .balance)
        // Decimal(string:) accepts numeric prefixes; require the entire reported
        // balance to be a decimal before displaying it as credits. Codex can
        // report a negative balance when concurrent usage depletes credits.
        let balance = rawBalance.flatMap { value -> Decimal? in
            guard value.range(of: #"\A-?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil else {
                return nil
            }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
        }
        self.init(
            hasCredits: try container.decode(Bool.self, forKey: .hasCredits),
            unlimited: try container.decode(Bool.self, forKey: .unlimited),
            balance: balance
        )
    }

    func formattedBalance(compact: Bool = false, locale: Locale = .current) -> String? {
        if unlimited { return compact ? "∞" : "Unlimited" }
        guard let balance else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.roundingMode = .floor
        formatter.maximumFractionDigits = 2
        if balance > 0, balance < Decimal(string: "0.01")! {
            return "<" + formatter.string(from: NSDecimalNumber(string: "0.01"))!
        }

        if compact {
            for (threshold, suffix): (Decimal, String) in [
                (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "k")
            ] where abs(balance) >= threshold {
                formatter.maximumFractionDigits = abs(balance) / threshold >= 100 ? 0 : 1
                return formatter.string(from: NSDecimalNumber(decimal: balance / threshold))
                    .map { $0 + suffix }
            }
        }
        if compact, abs(balance) >= 1 {
            formatter.maximumFractionDigits = abs(balance) >= 100 ? 0 : 1
        }
        return formatter.string(from: NSDecimalNumber(decimal: balance))
    }
}

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
    let credits: CodexCredits?
    let fetchedAt: Date

    init(
        shortTerm: CodexUsageWindow?,
        weekly: CodexUsageWindow?,
        credits: CodexCredits? = nil,
        fetchedAt: Date = Date()
    ) {
        self.shortTerm = shortTerm
        self.weekly = weekly
        self.credits = credits
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
        credits = rateLimit.credits
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
