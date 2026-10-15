import Foundation
import Security

protocol ClaudeSecretStoring: Sendable {
    func read(service: String, account: String, interactive: Bool) throws -> Data?
    func write(_ data: Data, service: String, account: String, interactive: Bool) throws
    func remove(service: String, account: String, interactive: Bool) throws
}

/// All Security.framework calls use this serialized gate. Legacy macOS Keychain
/// queries need the process-level UI guard as well as the per-query UI flag.
final class ClaudeKeychain: ClaudeSecretStoring, @unchecked Sendable {
    private static let gate = NSLock()

    private func guarded<T>(_ interactive: Bool, _ body: () throws -> T) throws -> T {
        Self.gate.lock()
        defer { Self.gate.unlock() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else {
            throw ClaudeAccountError.keychainAuthorization
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }

    private func query(service: String, account: String, interactive: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
    }

    func read(service: String, account: String, interactive: Bool) throws -> Data? {
        try guarded(interactive) {
            var q = query(service: service, account: account, interactive: interactive)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = value as? Data else { throw ClaudeAccountError.keychainAuthorization }
            return data
        }
    }

    func write(_ data: Data, service: String, account: String, interactive: Bool) throws {
        try guarded(interactive) {
            let q = query(service: service, account: account, interactive: interactive)
            var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = q
                attributes[kSecValueData as String] = data
                status = SecItemAdd(attributes as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw ClaudeAccountError.keychainAuthorization }
        }
    }

    func remove(service: String, account: String, interactive: Bool) throws {
        try guarded(interactive) {
            let status = SecItemDelete(query(service: service, account: account, interactive: interactive) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ClaudeAccountError.keychainAuthorization }
        }
    }
}

struct ClaudeAccountPaths: Sendable {
    let home: URL
    let root: URL
    var configHome: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    var config: URL {
        let legacy = configHome.appendingPathComponent(".config.json")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : home.appendingPathComponent(".claude.json")
    }
    var cswap: URL { home.appendingPathComponent(".claude-swap-backup", isDirectory: true) }
    var manifest: URL { root.appendingPathComponent("accounts.json") }
    var recovery: URL { root.appendingPathComponent("pending-switch.json") }
    var lockDirectories: [URL] {
        [configHome.appendingPathComponent(".oauth_refresh.lock"), home.appendingPathComponent(".claude.lock"),
         URL(fileURLWithPath: config.path + ".lock")]
    }
    static var live: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(home: home, root: home.appendingPathComponent("Library/Application Support/com.bchen.CodexUsageMenuBar/ClaudeAccounts"))
    }
}

enum ClaudePrivateFile {
    static func check(_ url: URL) throws {
        // Reject symlinks in every existing component, not just the leaf.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ClaudeAccountError.storage
        }
    }
    static func read(_ url: URL) throws -> Data {
        try check(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw ClaudeAccountError.invalidData }
        return try Data(contentsOf: url)
    }
    static func write(_ data: Data, to url: URL) throws {
        try check(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".agent-usage-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ClaudeAccountError.storage
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw ClaudeAccountError.storage }
    }
}

/// Cooperates with Claude Code's mkdir-based refresh/config locks. Never steals
/// a lock, including one that merely looks old after sleep. Network stays outside.
final class ClaudeAccountLocks {
    private var acquired: [URL] = []
    private var inodes: [UInt64] = []
    private let queue = DispatchQueue(label: "com.bchen.AgentUsage.ClaudeLockHeartbeat")
    private var heartbeat: DispatchSourceTimer?
    init(paths: ClaudeAccountPaths) throws {
        do {
            for url in paths.lockDirectories {
                try ClaudePrivateFile.check(url)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard mkdir(url.path, 0o700) == 0 else { throw ClaudeAccountError.busy }
                acquired.append(url)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                inodes.append((attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            }
            let records = Array(zip(acquired, inodes))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler {
                for (url, inode) in records where Self.isOwned(url, inode: inode) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                }
            }
            heartbeat = timer; timer.resume()
        } catch { release(); throw error }
    }
    private static func isOwned(_ url: URL, inode: UInt64) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return inode != 0 && (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value == inode
    }
    func release() {
        heartbeat?.cancel(); heartbeat = nil
        queue.sync {
            for (url, inode) in zip(acquired, inodes).reversed() where Self.isOwned(url, inode: inode) { _ = rmdir(url.path) }
        }
        acquired.removeAll(); inodes.removeAll()
    }
    deinit { release() }
}
