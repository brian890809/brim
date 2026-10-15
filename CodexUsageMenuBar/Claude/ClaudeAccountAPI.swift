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
        let limits = value["limits"] as? [[String: Any]] ?? []
        func unscoped(_ kind: String, legacyKey: String) -> ClaudeUsageSnapshot.UsageWindow? {
            let rows = limits.filter { ($0["kind"] as? String) == kind &&
                ($0["scope"] == nil || $0["scope"] is NSNull) }
            // A present but invalid/ambiguous modern row must not resurrect a legacy value.
            if !rows.isEmpty {
                return rows.count == 1 ? decodeWindow(rows[0], percentKey: "percent", now: now) : nil
            }
            return decodeWindow(value[legacyKey], now: now)
        }
        // Match the model-scoped row exactly as Claude Code does. Never alias
        // seven_day_opus or an undocumented internal bucket to Fable.
        let fableRows = limits.filter { row in
            guard row["kind"] as? String == "weekly_scoped",
                  let scope = row["scope"] as? [String: Any],
                  scope["surface"] == nil || scope["surface"] is NSNull,
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String else { return false }
            return name.caseInsensitiveCompare("Fable") == .orderedSame
        }
        let rateLimits = ClaudeUsageSnapshot.RateLimits(
            fiveHour: unscoped("session", legacyKey: "five_hour"),
            weekly: unscoped("weekly_all", legacyKey: "seven_day"),
            fable: fableRows.count == 1 ? decodeWindow(fableRows[0], percentKey: "percent", now: now) : nil
        )
        guard ClaudeUsagePeriod.allCases.contains(where: { rateLimits[$0] != nil }) else {
            throw ClaudeAccountError.invalidData
        }
        return .init(version: 4, updatedAt: now, rateLimits: rateLimits)
    }

    private static func decodeWindow(
        _ value: Any?, percentKey: String = "utilization", now: Date
    ) -> ClaudeUsageSnapshot.UsageWindow? {
        guard let window = value as? [String: Any],
              let number = window[percentKey] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let used = number.doubleValue
        guard used.isFinite, (0...100).contains(used) else { return nil }
        if used == 0, window["resets_at"] is NSNull {
            return .init(usedPercentage: 0, resetsAt: nil, state: .notStarted)
        } else {
            guard let raw = window["resets_at"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = formatter.date(from: raw)
            if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: raw) }
            guard let date, date > now else { return nil }
            return .init(usedPercentage: used, resetsAt: date)
        }
    }
}
