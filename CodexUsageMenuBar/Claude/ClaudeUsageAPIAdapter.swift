import Foundation
import LocalAuthentication
import Security

protocol ClaudeUsageProviding: Sendable {
    func fetchUsage(allowInteraction: Bool) async throws -> ClaudeUsageSnapshot
}

enum ClaudeUsageAPIError: LocalizedError, Equatable {
    case signInRequired, keychainAccessRequired, missingScope
    case invalidResponse, noWindow, network, rateLimited
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in again with Claude Code to refresh usage."
        case .keychainAccessRequired: return "Click Refresh to allow Claude Keychain access."
        case .missingScope: return "Claude sign-in lacks usage access. Sign in again with Claude Code."
        case .invalidResponse: return "Claude returned an unsupported usage response."
        case .noWindow: return "Claude hasn't reported a 5-hour window yet."
        case .network: return "Couldn't connect to Claude. Try Refresh again."
        case .rateLimited: return "Claude usage checks are limited. Try again in a few minutes."
        case .server(let status): return "Claude usage is unavailable (HTTP \(status))."
        }
    }
}

/// Internal subscription API isolated from the UI. No credentials are saved,
/// refreshed, printed, or passed to a subprocess; Claude Code owns its login.
actor ClaudeUsageAPIAdapter: ClaudeUsageProviding {
    typealias CredentialReader = @Sendable (Bool) throws -> Data
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let credentialReader: CredentialReader
    private let transport: Transport
    private var blockedUntil: Date?

    init(
        credentialReader: @escaping CredentialReader = { try ClaudeKeychain.read(allowInteraction: $0) },
        transport: @escaping Transport = { try await ClaudeUsageHTTP.get($0) }
    ) {
        self.credentialReader = credentialReader
        self.transport = transport
    }

    func fetchUsage(allowInteraction: Bool) async throws -> ClaudeUsageSnapshot {
        if let blockedUntil, blockedUntil > Date() { throw ClaudeUsageAPIError.rateLimited }
        let reader = credentialReader
        let credentialData = try await Task.detached(priority: .utility) {
            try reader(allowInteraction)
        }.value
        try Task.checkCancellation()
        let token = try Self.accessToken(from: credentialData)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentUsage/0.1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ClaudeUsageAPIError.network }
        // Never put raw server response bodies or networking errors in the UI.
        switch response.statusCode {
        case 200: return try Self.snapshot(from: data)
        case 401: throw ClaudeUsageAPIError.signInRequired
        case 403: throw ClaudeUsageAPIError.missingScope
        case 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let seconds = TimeInterval(raw).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 300
            blockedUntil = Date().addingTimeInterval(max(60, seconds))
            throw ClaudeUsageAPIError.rateLimited
        default: throw ClaudeUsageAPIError.server(response.statusCode)
        }
    }

    private static func accessToken(from data: Data) throws -> String {
        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double?
                let scopes: [String]?
            }
            let claudeAiOauth: OAuth?
        }
        guard let credential = try? JSONDecoder().decode(Envelope.self, from: data).claudeAiOauth,
              !credential.accessToken.isEmpty,
              !credential.accessToken.contains(where: { $0.isWhitespace })
        else { throw ClaudeUsageAPIError.signInRequired }
        if let expiry = credential.expiresAt,
           !expiry.isFinite || expiry / 1000 <= Date().timeIntervalSince1970 {
            throw ClaudeUsageAPIError.signInRequired
        }
        if let scopes = credential.scopes, !scopes.contains("user:profile") {
            throw ClaudeUsageAPIError.missingScope
        }
        return credential.accessToken
    }

    private static func snapshot(from data: Data) throws -> ClaudeUsageSnapshot {
        struct Response: Decodable {
            struct Window: Decodable {
                let utilization: Double
                let resets_at: String
            }
            let five_hour: Window?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ClaudeUsageAPIError.invalidResponse
        }
        guard let window = response.five_hour else { throw ClaudeUsageAPIError.noWindow }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var reset = formatter.date(from: window.resets_at)
        if reset == nil {
            formatter.formatOptions = [.withInternetDateTime]
            reset = formatter.date(from: window.resets_at)
        }
        guard let reset, window.utilization.isFinite, (0...100).contains(window.utilization) else {
            throw ClaudeUsageAPIError.invalidResponse
        }
        guard reset > Date() else { throw ClaudeUsageAPIError.noWindow }
        return ClaudeUsageSnapshot(version: 2, updatedAt: Date(), rateLimits: .init(
            fiveHour: .init(usedPercentage: window.utilization, resetsAt: reset)
        ))
    }
}

private enum ClaudeKeychain {
    static func read(allowInteraction: Bool) throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        context.localizedReason = "Allow Agent Usage to read your Claude usage."
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        // LAContext alone doesn't consistently suppress legacy generic-password
        // ACL dialogs. Keep the explicit fail-without-UI flag for unattended reads.
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw ClaudeUsageAPIError.keychainAccessRequired
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClaudeUsageAPIError.signInRequired
        }
        return data
    }
}

private enum ClaudeUsageHTTP {
    static func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClaudeUsageAPIError.invalidResponse }
        return (data, response)
    }

    /// Reject redirects so the bearer credential can only reach the fixed API URL.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
