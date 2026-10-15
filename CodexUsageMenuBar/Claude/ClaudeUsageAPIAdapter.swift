import Foundation

protocol ClaudeUsageProviding: Sendable {
    func fetchUsage(allowInteraction: Bool) async throws -> ClaudeUsageSnapshot
}

/// Safe presentation errors shared by the app-owned Claude browser adapter.
/// Deliberately no foreign Keychain reader or token-handling implementation.
enum ClaudeUsageAPIError: LocalizedError, Equatable {
    case signInRequired, webVerificationRequired, organizationSelectionRequired, noUsageOrganization
    case invalidResponse, noWindow, network, rateLimited
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Connect Claude in this app to load usage."
        case .webVerificationRequired: return "Open Claude connection to complete browser verification."
        case .organizationSelectionRequired: return "Choose an organization in Claude connection."
        case .noUsageOrganization: return "Signed in, but this account has no Claude chat organization."
        case .invalidResponse: return "Claude returned an unsupported usage response."
        case .noWindow: return "Claude hasn't reported a 5-hour window yet."
        case .network: return "Couldn't connect to Claude. Try Refresh again."
        case .rateLimited: return "Claude usage checks are limited. Try again in a few minutes."
        case .server(let status): return "Claude usage is unavailable (HTTP \(status))."
        }
    }
}
