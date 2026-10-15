import Foundation

protocol ClaudeAccountsProviding: Sendable {
    func inventory() async throws -> ClaudeAccountInventory
    func importAccount(_ candidate: ClaudeImportCandidate) async throws
    func saveCurrent() async throws -> ClaudeAccount
    func activate(_ id: String) async throws
    func restorePrevious() async throws
    func unlockSavedLogins() async throws
    func usage(_ id: String) async throws -> ClaudeUsageSnapshot
}

actor ClaudeAccountService: ClaudeAccountsProviding {
    static let vaultService = "com.bchen.AgentUsage.ClaudeAccounts"
    static let liveService = "Claude Code-credentials"
    private let paths: ClaudeAccountPaths
    private let secrets: any ClaudeSecretStoring
    private let api: any ClaudeAccountNetworking
    private let username: String
    private var busy = false
    private var operationLock: Int32 = -1
    private let validateEnvironment: Bool

    init(paths: ClaudeAccountPaths = .live, secrets: any ClaudeSecretStoring = ClaudeKeychain(),
         api: any ClaudeAccountNetworking = ClaudeAccountAPI(), username: String = NSUserName(),
         validateEnvironment: Bool = true) {
        self.paths = paths; self.secrets = secrets; self.api = api; self.username = username
        self.validateEnvironment = validateEnvironment
    }

    private func begin() throws {
        guard !busy else { throw ClaudeAccountError.busy }
        if validateEnvironment {
            let env = ProcessInfo.processInfo.environment
            guard env["CLAUDE_CONFIG_DIR"] == nil, env["ANTHROPIC_API_KEY"] == nil,
                  env["CLAUDE_CODE_OAUTH_TOKEN"] == nil else { throw ClaudeAccountError.unsupportedConfiguration }
        }
        try ClaudePrivateFile.check(paths.root)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = paths.root.appendingPathComponent(".operation.lock")
        try ClaudePrivateFile.check(lockURL)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClaudeAccountError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ClaudeAccountError.busy }
        operationLock = fd
        busy = true
    }

    private func end() {
        if operationLock >= 0 { _ = flock(operationLock, LOCK_UN); close(operationLock); operationLock = -1 }
        busy = false
    }

    private func accounts() throws -> [ClaudeAccount] {
        guard FileManager.default.fileExists(atPath: paths.manifest.path) else { return [] }
        guard let result = try? JSONDecoder().decode([ClaudeAccount].self, from: ClaudePrivateFile.read(paths.manifest)) else {
            throw ClaudeAccountError.storage
        }
        return result
    }

    private func configData() throws -> Data { try ClaudePrivateFile.read(paths.config) }
    private func validateTarget(_ account: ClaudeAccount) throws {
        var settings = [paths.configHome.appendingPathComponent("settings.json")]
        if validateEnvironment {
            settings.append(URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"))
        }
        for url in settings where FileManager.default.fileExists(atPath: url.path) {
            let value = try ClaudeSavedLogin.object(ClaudePrivateFile.read(url))
            if let method = value["forceLoginMethod"] as? String, method != "claudeai" { throw ClaudeAccountError.unsupportedConfiguration }
            if let org = value["forceLoginOrgUUID"] as? String, org.lowercased() != account.organizationID {
                throw ClaudeAccountError.unsupportedConfiguration
            }
            if let orgs = value["forceLoginOrgUUID"] as? [String], !orgs.map({ $0.lowercased() }).contains(account.organizationID) {
                throw ClaudeAccountError.unsupportedConfiguration
            }
            let env = value["env"] as? [String: Any] ?? [:]
            if value["apiKeyHelper"] != nil || env["ANTHROPIC_API_KEY"] != nil || env["CLAUDE_CODE_OAUTH_TOKEN"] != nil {
                throw ClaudeAccountError.unsupportedConfiguration
            }
        }
    }
    private func identity(_ data: Data) throws -> ClaudeAccount {
        guard let oauth = try ClaudeSavedLogin.object(data)["oauthAccount"] as? [String: Any] else { throw ClaudeAccountError.noLogin }
        return try ClaudeAccount(oauth: oauth)
    }
    private func liveLogin(interactive: Bool) throws -> (Data, ClaudeSavedLogin) {
        // A file fallback can conflict with the Keychain. Don't guess which wins.
        guard !FileManager.default.fileExists(atPath: paths.configHome.appendingPathComponent(".credentials.json").path) else {
            throw ClaudeAccountError.unsupportedConfiguration
        }
        let config = try configData()
        guard let oauth = try ClaudeSavedLogin.object(config)["oauthAccount"] as? [String: Any],
              let credentials = try secrets.read(service: Self.liveService, account: username, interactive: interactive) else {
            throw ClaudeAccountError.noLogin
        }
        return (config, try ClaudeSavedLogin(oauthAccount: oauth, credentials: credentials))
    }

    private func saved(_ id: String, interactive: Bool) throws -> ClaudeSavedLogin {
        guard try accounts().contains(where: { $0.id == id }),
              let data = try secrets.read(service: Self.vaultService, account: id, interactive: interactive),
              let login = try? JSONDecoder().decode(ClaudeSavedLogin.self, from: data), login.account.id == id else {
            throw ClaudeAccountError.keychainAuthorization
        }
        _ = try login.accessToken()
        return login
    }
    private func persist(_ login: ClaudeSavedLogin, interactive: Bool) throws {
        try secrets.write(JSONEncoder().encode(login), service: Self.vaultService, account: login.account.id, interactive: interactive)
        var list = try accounts()
        list.removeAll { $0.id == login.account.id }
        list.append(login.account)
        list.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        try ClaudePrivateFile.write(JSONEncoder().encode(list), to: paths.manifest)
    }

    func inventory() throws -> ClaudeAccountInventory {
        let list = try accounts()
        let current = try? identity(configData()).id
        let sequence = paths.cswap.appendingPathComponent("sequence.json")
        var candidates: [ClaudeImportCandidate] = []
        var unavailable: [String] = []
        if FileManager.default.fileExists(atPath: sequence.path) {
            let object = try ClaudeSavedLogin.object(ClaudePrivateFile.read(sequence))
            for (slot, value) in object["accounts"] as? [String: [String: Any]] ?? [:] {
                guard let number = Int(slot), number > 0, String(number) == slot else { continue }
                guard let account = try? ClaudeAccount(oauth: ["accountUuid": value["uuid"] ?? "",
                        "organizationUuid": value["organizationUuid"] ?? "", "emailAddress": value["email"] ?? "",
                        "organizationName": value["organizationName"] ?? ""]) else {
                    let label = String((value["email"] as? String ?? "Account \(slot)").prefix(254))
                    unavailable.append(label)
                    continue
                }
                if !list.contains(where: { $0.id == account.id }) { candidates.append(.init(slot: slot, account: account)) }
            }
        }
        candidates.sort { $0.slot.localizedStandardCompare($1.slot) == .orderedAscending }
        return .init(accounts: list, candidates: candidates, activeID: current,
                     needsRecovery: FileManager.default.fileExists(atPath: paths.recovery.path), unavailableAccounts: unavailable.sorted())
    }

    func importAccount(_ candidate: ClaudeImportCandidate) async throws {
        try begin(); defer { end() }
        guard try inventory().candidates.contains(candidate) else { throw ClaudeAccountError.changed }
        // Source remains untouched. File backups are base64, not encryption.
        let filename = ".claude-config-\(candidate.slot)-\(candidate.account.email).json"
        let source = paths.cswap.appendingPathComponent("configs").appendingPathComponent(filename)
        guard let oauth = try ClaudeSavedLogin.object(ClaudePrivateFile.read(source))["oauthAccount"] as? [String: Any] else {
            throw ClaudeAccountError.invalidData
        }
        let file = paths.cswap.appendingPathComponent("credentials").appendingPathComponent(".creds-\(candidate.slot)-\(candidate.account.email).enc")
        let credentials: Data
        if FileManager.default.fileExists(atPath: file.path) {
            guard let decoded = Data(base64Encoded: try ClaudePrivateFile.read(file), options: [.ignoreUnknownCharacters]) else {
                throw ClaudeAccountError.invalidData
            }
            credentials = decoded
        } else {
            guard let data = try secrets.read(service: "claude-swap", account: "account-\(candidate.slot)-\(candidate.account.email)", interactive: true) else {
                throw ClaudeAccountError.noLogin
            }
            credentials = data
        }
        let login = try ClaudeSavedLogin(oauthAccount: oauth, credentials: credentials)
        guard login.account.id == candidate.account.id else { throw ClaudeAccountError.identityMismatch }
        if !login.expiresSoon { try await api.verify(login) }
        try persist(login, interactive: true)
    }

    func saveCurrent() async throws -> ClaudeAccount {
        try begin(); defer { end() }
        guard !FileManager.default.fileExists(atPath: paths.recovery.path) else { throw ClaudeAccountError.recoveryRequired }
        let (original, login) = try liveLogin(interactive: true)
        try await api.verify(login)
        _ = try secrets.read(service: Self.vaultService, account: login.account.id, interactive: true)
        let locks = try ClaudeAccountLocks(paths: paths); defer { locks.release() }
        let (latest, current) = try liveLogin(interactive: false)
        guard original == latest, login.credentials == current.credentials else { throw ClaudeAccountError.changed }
        try persist(login, interactive: false)
        return login.account
    }

    private struct Recovery: Codable {
        let config: Data
        let credentials: Data
        let replacementConfig: Data
        let replacementCredentials: Data
    }

    func activate(_ id: String) async throws {
        try begin(); defer { end() }
        guard !FileManager.default.fileExists(atPath: paths.recovery.path) else { throw ClaudeAccountError.recoveryRequired }
        var target = try saved(id, interactive: true)
        try validateTarget(target.account)
        let (originalConfig, original) = try liveLogin(interactive: true)
        if original.account.id == id {
            try await api.verify(original)
            let locks = try ClaudeAccountLocks(paths: paths); defer { locks.release() }
            let (latestConfig, latest) = try liveLogin(interactive: false)
            guard latestConfig == originalConfig, latest.credentials == original.credentials else { throw ClaudeAccountError.changed }
            try persist(original, interactive: false)
            return
        }
        // Only an explicit switch can renew an inactive subscription. Background
        // usage never rotates a refresh token shared with a running CLI/session.
        if target.expiresSoon {
            target = try await api.renew(target)
            // Save the newly rotated token before any later verification can fail.
            try persist(target, interactive: true)
        }
        try await api.verify(target)
        try await api.verify(original)
        var replacement = try ClaudeSavedLogin.object(originalConfig)
        replacement["oauthAccount"] = try ClaudeSavedLogin.object(target.oauthAccount)
        let replacementConfig = try JSONSerialization.data(withJSONObject: replacement, options: [.sortedKeys])
        let replacementCredentials = try ClaudeSavedLogin.mergedCredentials(target: target.credentials, live: original.credentials)
        let recovery = Recovery(config: originalConfig, credentials: original.credentials,
            replacementConfig: replacementConfig, replacementCredentials: replacementCredentials)
        // Obtain app-owned Keychain authorization before taking Claude's short locks.
        try persist(original, interactive: true)
        try secrets.write(JSONEncoder().encode(recovery), service: Self.vaultService, account: "pending-switch", interactive: true)
        let locks = try ClaudeAccountLocks(paths: paths); defer { locks.release() }
        let (latestConfig, latest) = try liveLogin(interactive: false)
        guard latestConfig == originalConfig, latest.credentials == original.credentials else { throw ClaudeAccountError.changed }
        try ClaudePrivateFile.write(Data("{\"version\":1}".utf8), to: paths.recovery)
        do {
            try secrets.write(replacementCredentials, service: Self.liveService, account: username, interactive: false)
            try ClaudePrivateFile.write(replacementConfig, to: paths.config)
            let (writtenConfig, written) = try liveLogin(interactive: false)
            guard writtenConfig == replacementConfig, written.account.id == id, written.credentials == replacementCredentials else {
                throw ClaudeAccountError.changed
            }
            try clearRecovery()
        } catch {
            do {
                try secrets.write(original.credentials, service: Self.liveService, account: username, interactive: false)
                try ClaudePrivateFile.write(originalConfig, to: paths.config)
                try clearRecovery()
            } catch { throw ClaudeAccountError.recoveryRequired }
            throw ClaudeAccountError.rolledBack
        }
    }

    private func clearRecovery() throws {
        // Keep the encrypted rollback snapshot until the next switch. The public
        // marker is the commit record; clearing it is the final transaction step.
        try FileManager.default.removeItem(at: paths.recovery)
    }

    func restorePrevious() throws {
        try begin(); defer { end() }
        guard FileManager.default.fileExists(atPath: paths.recovery.path),
              let data = try secrets.read(service: Self.vaultService, account: "pending-switch", interactive: true),
              let recovery = try? JSONDecoder().decode(Recovery.self, from: data) else { throw ClaudeAccountError.storage }
        _ = try liveLogin(interactive: true)
        let locks = try ClaudeAccountLocks(paths: paths); defer { locks.release() }
        let (config, login) = try liveLogin(interactive: false)
        guard (config == recovery.config || config == recovery.replacementConfig),
              (login.credentials == recovery.credentials || login.credentials == recovery.replacementCredentials) else {
            throw ClaudeAccountError.changed // Never roll back over a newer external login.
        }
        try secrets.write(recovery.credentials, service: Self.liveService, account: username, interactive: false)
        try ClaudePrivateFile.write(recovery.config, to: paths.config)
        try clearRecovery()
    }

    func usage(_ id: String) async throws -> ClaudeUsageSnapshot {
        try begin(); defer { end() }
        guard !FileManager.default.fileExists(atPath: paths.recovery.path) else { throw ClaudeAccountError.recoveryRequired }
        let login = try saved(id, interactive: false)
        do { return try await api.usage(login) }
        catch let error as ClaudeAccountError {
            // A stale copy does not mean the user's CLI is signed out. Never
            // rotate its shared refresh token or reopen sign-in from polling.
            if (error == .expired || error == .denied(401)),
               (try? identity(configData()).id) == id {
                throw ClaudeAccountError.activeLoginNeedsSync
            }
            throw error
        }
    }

    func unlockSavedLogins() throws {
        try begin(); defer { end() }
        for account in try accounts() { _ = try saved(account.id, interactive: true) }
    }
}
