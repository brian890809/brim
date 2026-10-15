import Foundation
import CoreFoundation

protocol ClaudeAccountNetworking: Sendable {
    func verify(_ login: ClaudeSavedLogin) async throws
    func renew(_ login: ClaudeSavedLogin) async throws -> ClaudeSavedLogin
    func usage(_ login: ClaudeSavedLogin) async throws -> ClaudeUsageSnapshot
}

private final class ClaudeNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Native implementation of the OAuth profile/usage contract used by cswap.
/// No Python, cswap process, browser-cookie import, or token in command arguments.
actor ClaudeAccountAPI: ClaudeAccountNetworking {
    private let session: URLSession
    private var blockedUntil: Date?

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: ClaudeNoRedirects(), delegateQueue: nil)
    }

    private func request(_ path: String, token: String? = nil, body: Data? = nil) async throws -> [String: Any] {
        if let blockedUntil, blockedUntil > Date() { throw ClaudeAccountError.rateLimited }
        let base = body == nil ? "https://api.anthropic.com" : "https://platform.claude.com"
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AgentUsage/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ClaudeAccountError.network }
        guard let http = response as? HTTPURLResponse else { throw ClaudeAccountError.network }
        if http.statusCode == 429 {
            let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
            blockedUntil = Date().addingTimeInterval(seconds.isFinite ? min(3600, max(60, seconds)) : 300)
            throw ClaudeAccountError.rateLimited
        }
        guard http.statusCode == 200 else { throw ClaudeAccountError.denied(http.statusCode) }
        return try ClaudeSavedLogin.object(data)
    }

    func verify(_ login: ClaudeSavedLogin) async throws {
        let result = try await request("/api/oauth/profile", token: login.accessToken())
        guard let account = result["account"] as? [String: Any],
              let user = account["uuid"] as? String,
              let organization = result["organization"] as? [String: Any],
              let org = organization["uuid"] as? String,
              user.lowercased() == login.account.userID.lowercased(),
              org.lowercased() == login.account.organizationID.lowercased() else {
            throw ClaudeAccountError.identityMismatch
        }
    }

    func renew(_ login: ClaudeSavedLogin) async throws -> ClaudeSavedLogin {
        var object = try ClaudeSavedLogin.object(login.credentials)
        guard var oauth = object["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else { throw ClaudeAccountError.expired }
        let body = try JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token",
            "refresh_token": refresh, "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
        let result = try await request("/v1/oauth/token", body: body)
        guard let token = result["access_token"] as? String, !token.isEmpty,
              let seconds = result["expires_in"] as? Double, seconds.isFinite, seconds > 0 else {
            throw ClaudeAccountError.invalidData
        }
        oauth["accessToken"] = token
        oauth["expiresAt"] = (Date().timeIntervalSince1970 + seconds) * 1000
        if let refresh = result["refresh_token"] as? String { oauth["refreshToken"] = refresh }
        if let scope = result["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        object["claudeAiOauth"] = oauth
        var renewed = login
        renewed.credentials = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return renewed
    }

    func usage(_ login: ClaudeSavedLogin) async throws -> ClaudeUsageSnapshot {
        guard !login.expiresSoon else { throw ClaudeAccountError.expired }
        try await verify(login)
        return try Self.decodeUsage(await request("/api/oauth/usage", token: login.accessToken()))
    }

    static func decodeUsage(_ value: [String: Any], now: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard let window = value["five_hour"] as? [String: Any],
              let used = window["utilization"] as? Double, used.isFinite, (0...100).contains(used),
              let number = window["utilization"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw ClaudeAccountError.invalidData }
        let parsed: ClaudeUsageSnapshot.UsageWindow
        if used == 0, window["resets_at"] is NSNull {
            parsed = .init(usedPercentage: 0, resetsAt: nil, state: .notStarted)
        } else {
            guard let raw = window["resets_at"] as? String else { throw ClaudeAccountError.invalidData }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: raw)
            if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: raw) }
            guard let date, date > now else { throw ClaudeAccountError.invalidData }
            parsed = .init(usedPercentage: used, resetsAt: date)
        }
        return .init(version: 3, updatedAt: now, rateLimits: .init(fiveHour: parsed))
    }
}
