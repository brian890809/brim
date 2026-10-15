import Foundation

/// Public metadata only. Secrets never enter the account list, UserDefaults, or logs.
struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    let userID: String
    let organizationID: String
    let email: String
    let organizationName: String
    var id: String { userID.lowercased() + ":" + organizationID.lowercased() }
    var label: String { organizationName.isEmpty ? email : "\(email) · \(organizationName)" }

    init(oauth: [String: Any]) throws {
        guard let user = oauth["accountUuid"] as? String, UUID(uuidString: user) != nil,
              let org = oauth["organizationUuid"] as? String, UUID(uuidString: org) != nil,
              let email = oauth["emailAddress"] as? String, !email.isEmpty, email.count <= 254,
              !email.contains("/"), !email.contains("\\"), !email.contains(where: { $0.isNewline })
        else { throw ClaudeAccountError.invalidData }
        userID = user.lowercased()
        organizationID = org.lowercased()
        self.email = email
        organizationName = String((oauth["organizationName"] as? String ?? "").prefix(120))
    }

    init(userID: String, organizationID: String, email: String, organizationName: String = "") {
        self.userID = userID; self.organizationID = organizationID
        self.email = email; self.organizationName = organizationName
    }
}

struct ClaudeImportCandidate: Identifiable, Equatable, Sendable {
    let slot: String
    let account: ClaudeAccount
    var id: String { account.id }
}

struct ClaudeAccountInventory: Sendable {
    var accounts: [ClaudeAccount]
    var candidates: [ClaudeImportCandidate]
    var activeID: String?
    var needsRecovery: Bool
    var unavailableAccounts: [String] = []
}

enum ClaudeAccountError: LocalizedError, Equatable {
    case invalidData, noLogin, keychainAuthorization, storage, busy, changed, identityMismatch
    case expired, activeLoginNeedsSync, network, denied(Int), rateLimited, recoveryRequired, rolledBack, unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidData: return "The saved Claude account is incomplete or unsupported. Save it again from Claude Code."
        case .noLogin: return "Open Accounts to save or import the active Claude Code login."
        case .keychainAuthorization: return "Keychain access is unavailable. Open Accounts to unlock saved logins or save the current login."
        case .storage: return "Account storage could not be updated. No account switch was confirmed."
        case .busy: return "Another account operation is running. Try again after it finishes."
        case .changed: return "Claude's login changed during this operation. Nothing was overwritten; try again."
        case .identityMismatch: return "The saved credential belongs to a different account or organization. Import it again."
        case .expired: return "This saved sign-in needs renewal. Set active to renew it, or sign in with Claude Code and save the login again."
        case .activeLoginNeedsSync: return "Saved login needs syncing. Open Accounts → Save current login."
        case .network: return "Claude could not be reached. Try again when connected."
        case .denied(let status): return "Claude denied this account request (HTTP \(status)). No login was changed."
        case .rateLimited: return "Claude is limiting account requests. Wait a few minutes before trying again."
        case .recoveryRequired: return "An account switch was interrupted. Restore the previous login before switching again."
        case .rolledBack: return "The switch failed. The previous login was restored."
        case .unsupportedConfiguration: return "This preview switches the default Claude Code subscription only. Custom config directories and API-key overrides are not supported."
        }
    }
}

/// Opaque credential data stays inside the service and Keychain. Do not print this type.
struct ClaudeSavedLogin: Codable, Sendable {
    let account: ClaudeAccount
    let oauthAccount: Data
    var credentials: Data

    init(oauthAccount: [String: Any], credentials: Data) throws {
        account = try ClaudeAccount(oauth: oauthAccount)
        self.oauthAccount = try JSONSerialization.data(withJSONObject: oauthAccount, options: [.sortedKeys])
        self.credentials = credentials
        _ = try accessToken()
    }

    func accessToken() throws -> String {
        let data = try Self.object(credentials)
        guard let oauth = data["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              !token.contains(where: { $0.isNewline }) else { throw ClaudeAccountError.invalidData }
        return token
    }

    var expiresSoon: Bool {
        guard let data = try? Self.object(credentials), let oauth = data["claudeAiOauth"] as? [String: Any],
              let ms = oauth["expiresAt"] as? Double, ms.isFinite else { return true }
        return Date().timeIntervalSince1970 * 1000 + 60_000 >= ms
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2_000_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClaudeAccountError.invalidData }
        return value
    }

    // Compatibility behavior derived from claude-swap (MIT; see bundled license).
    // Shared integrations belong to the machine, not the selected subscription.
    static let sharedKeys: Set<String> = ["mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets"]
    static func mergedCredentials(target: Data, live: Data) throws -> Data {
        var result = try object(target)
        let current = try object(live)
        for key in sharedKeys { result[key] = current[key] }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
}
