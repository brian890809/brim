import Foundation
import Security
import CryptoKit

protocol ClaudeSecretStoring: Sendable {
    func validateWrite(_ data: Data, service: String, account: String) throws
    func read(service: String, account: String, interactive: Bool) throws -> Data?
    func write(_ data: Data, service: String, account: String, interactive: Bool) throws
    func remove(service: String, account: String, interactive: Bool) throws
}

extension ClaudeSecretStoring {
    func validateWrite(_ data: Data, service: String, account: String) throws {}
}

/// All Security.framework calls use this serialized gate. Legacy macOS Keychain
/// queries need the process-level UI guard as well as the per-query UI flag.
final class ClaudeKeychain: ClaudeSecretStoring, @unchecked Sendable {
    fileprivate static let gate = NSLock()

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

/// The helper owns the Keychain items, so updating this app does not change
/// their creator. Never resolve through PATH, log output, or put secrets in argv.
struct ClaudeSecurityResult: Sendable {
    let status: Int32
    let output: Data
}

protocol ClaudeSecurityRunning: Sendable {
    func run(arguments: [String], input: Data?, interactive: Bool) throws -> ClaudeSecurityResult
}

struct ClaudeSecurityProcess: ClaudeSecurityRunning {
    func run(arguments: [String], input: Data?, interactive: Bool) throws -> ClaudeSecurityResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        // Do not inherit injection variables or shell initialization hooks.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "USER": NSUserName(), "LANG": "en_US.UTF-8"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // security can echo malformed stdin in diagnostics. Never retain it.
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let output = ClaudeSecurityOutput()
        let drained = DispatchSemaphore(value: 0)
        do { try process.run() } catch { throw ClaudeAccountError.keychainAuthorization }
        DispatchQueue.global(qos: .utility).async {
            while let bytes = try? stdout.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty {
                output.append(bytes)
            }
            drained.signal()
        }
        do {
            if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
            try stdin.fileHandleForWriting.close()
        } catch {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        // Interactive requests are explicit user actions; background failures
        // stop instead of retrying. A timeout is not a no-prompt guarantee.
        if done.wait(timeout: .now() + (interactive ? 120 : 5)) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = drained.wait(timeout: .now() + 1)
            throw ClaudeAccountError.keychainAuthorization
        }
        guard drained.wait(timeout: .now() + 1) == .success, !output.overflow else {
            throw ClaudeAccountError.storage
        }
        return .init(status: process.terminationStatus, output: output.data)
    }
}

private final class ClaudeSecurityOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count + data.count > 4_000_000 { exceeded = true } else { bytes.append(data) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
}

protocol ClaudeSecurityPreflighting: Sendable {
    /// Metadata only. Missing items may be created; existing items must already
    /// trust the helper for silent access. No access controls are changed.
    func check(service: String, account: String) throws -> Bool
}

struct ClaudeSecurityPreflight: ClaudeSecurityPreflighting {
    let keychainPath: String
    init(keychainPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Keychains/login.keychain-db").path) { self.keychainPath = keychainPath }

    func check(service: String, account: String) throws -> Bool {
        ClaudeKeychain.gate.lock(); defer { ClaudeKeychain.gate.unlock() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw ClaudeAccountError.keychainAuthorization }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainPath, &keychain) == errSecSuccess, let keychain else { throw ClaudeAccountError.keychainAuthorization }
        var state: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &state) == errSecSuccess,
              state & UInt32(kSecUnlockStateStatus) != 0 else { throw ClaudeAccountError.keychainAuthorization }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [keychain], kSecReturnRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess, let ref, CFGetTypeID(ref) == SecKeychainItemGetTypeID() else {
            throw ClaudeAccountError.keychainAuthorization
        }
        let item = unsafeBitCast(ref, to: SecKeychainItem.self)
        var access: SecAccess?
        var list: CFArray?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &list) == errSecSuccess, let entries = list as? [SecACL] else {
            throw ClaudeAccountError.keychainAuthorization
        }
        var decryptAllowed = false, partitionAllowed = false
        for entry in entries {
            guard let authorizations = SecACLCopyAuthorizations(entry) as? [String] else { continue }
            var apps: CFArray?, description: CFString?
            var selector = SecKeychainPromptSelector(rawValue: 0)
            guard SecACLCopyContents(entry, &apps, &description, &selector) == errSecSuccess else { continue }
            if authorizations.contains(kSecACLAuthorizationPartitionID as String), let description {
                partitionAllowed = Self.allowsSecurityPartition(description as String)
            }
            if authorizations.contains(kSecACLAuthorizationDecrypt as String), let trusted = apps as? [SecTrustedApplication] {
                decryptAllowed = trusted.contains {
                    var data: CFData?
                    guard SecTrustedApplicationCopyData($0, &data) == errSecSuccess, let data else { return false }
                    return (data as Data) == Data("/usr/bin/security\0".utf8)
                }
            }
        }
        guard decryptAllowed && partitionAllowed else { throw ClaudeAccountError.keychainAuthorization }
        return true
    }

    static func allowsSecurityPartition(_ hex: String) -> Bool {
        guard hex.count % 2 == 0, hex.count < 100_000 else { return false }
        var bytes = Data(), index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return false }
            bytes.append(byte); index = end
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let partitions = plist["Partitions"] as? [String] else { return false }
        return partitions.contains("apple-tool:")
    }
}

final class ClaudeSystemKeychain: ClaudeSecretStoring, @unchecked Sendable {
    private let runner: any ClaudeSecurityRunning
    private let preflight: any ClaudeSecurityPreflighting
    private let keychainPath: String
    private let lock = NSRecursiveLock()
    private var blocked = Set<String>()
    init(runner: any ClaudeSecurityRunning = ClaudeSecurityProcess(),
         preflight: (any ClaudeSecurityPreflighting)? = nil,
         keychainPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path) {
        self.runner = runner; self.keychainPath = keychainPath
        self.preflight = preflight ?? ClaudeSecurityPreflight(keychainPath: keychainPath)
    }

    static func quoted(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count < 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ClaudeAccountError.invalidData
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func operation<T>(service: String, account: String, interactive: Bool, body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        _ = try Self.quoted(service); _ = try Self.quoted(account)
        let key = service + "\n" + account
        if interactive { blocked.remove(key) }
        if !interactive {
            guard !blocked.contains(key) else { throw ClaudeAccountError.keychainAuthorization }
            _ = try preflight.check(service: service, account: account)
        }
        do {
            let value = try body()
            blocked.remove(key)
            return value
        } catch {
            blocked.insert(key)
            throw error
        }
    }

    func read(service: String, account: String, interactive: Bool) throws -> Data? {
        try operation(service: service, account: account, interactive: interactive) {
            let result = try runner.run(arguments: ["find-generic-password", "-s", service, "-a", account, "-w", keychainPath], input: nil, interactive: interactive)
            if result.status == 44 { return nil }
            guard result.status == 0 else { throw ClaudeAccountError.keychainAuthorization }
            var data = result.output
            if data.last == 10 { data.removeLast() }
            return data
        }
    }

    static func writeCommand(_ data: Data, service: String, account: String, keychainPath: String) throws -> Data {
        // A single stdin command, with only printable UTF-8 data. JSON produced
        // by our encoder and base64 chunks meet this contract. No argv fallback.
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw ClaudeAccountError.invalidData }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let command = "add-generic-password -U -s \(try quoted(service)) -a \(try quoted(account)) -w \"\(escaped)\" \(try quoted(keychainPath))\n"
        guard command.utf8.count <= 4032 else { throw ClaudeAccountError.credentialTooLarge }
        return Data(command.utf8)
    }

    func validateWrite(_ data: Data, service: String, account: String) throws {
        _ = try Self.writeCommand(data, service: service, account: account, keychainPath: keychainPath)
    }

    func write(_ data: Data, service: String, account: String, interactive: Bool) throws {
        let input = try Self.writeCommand(data, service: service, account: account, keychainPath: keychainPath)
        try operation(service: service, account: account, interactive: interactive) {
            let result = try runner.run(arguments: ["-i"], input: input, interactive: interactive)
            guard result.status == 0 else { throw ClaudeAccountError.keychainAuthorization }
            guard try read(service: service, account: account, interactive: false) == data else { throw ClaudeAccountError.storage }
        }
    }

    func remove(service: String, account: String, interactive: Bool) throws {
        try operation(service: service, account: account, interactive: interactive) {
            let result = try runner.run(arguments: ["delete-generic-password", "-s", service, "-a", account, keychainPath], input: nil, interactive: interactive)
            guard result.status == 0 || result.status == 44 else { throw ClaudeAccountError.keychainAuthorization }
        }
    }
}

/// Versioned, chunked Keychain storage. Each secret crosses only a pipe and the
/// Keychain; manifest replacement commits a complete, verified generation.
final class ClaudePersistentSecrets: ClaudeSecretStoring, @unchecked Sendable {
    static let vault = "com.bchen.AgentUsage.ClaudeAccounts"
    static let helperVault = vault + ".system-v1"
    private let helper: any ClaudeSecretStoring
    private let legacy: any ClaudeSecretStoring
    private let lock = NSRecursiveLock()
    private struct Manifest: Codable { let version: Int; let generation: UUID; let count: Int; let digest: String }
    init(helper: any ClaudeSecretStoring = ClaudeSystemKeychain(), legacy: any ClaudeSecretStoring = ClaudeKeychain()) {
        self.helper = helper; self.legacy = legacy
    }
    private func chunkAccount(_ account: String, _ manifest: Manifest, _ index: Int) -> String {
        "\(account).\(manifest.generation.uuidString).\(index)"
    }
    private func manifest(_ account: String, interactive: Bool) throws -> Manifest? {
        guard let bytes = try helper.read(service: Self.helperVault, account: account, interactive: interactive) else { return nil }
        guard let value = try? JSONDecoder().decode(Manifest.self, from: bytes), value.version == 1,
              (1...2048).contains(value.count) else { throw ClaudeAccountError.storage }
        return value
    }
    func validateWrite(_ data: Data, service: String, account: String) throws {
        if service == Self.vault {
            guard !data.isEmpty, data.count <= 2_000_000 else { throw ClaudeAccountError.invalidData }
        } else { try helper.validateWrite(data, service: service, account: account) }
    }
    func read(service: String, account: String, interactive: Bool) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard service == Self.vault else { return try helper.read(service: service, account: account, interactive: interactive) }
        guard let manifest = try manifest(account, interactive: interactive) else {
            guard interactive else { throw ClaudeAccountError.loginMigrationRequired }
            // Explicit, per-account migration. Preserve the original item.
            guard let original = try legacy.read(service: service, account: account, interactive: true) else { return nil }
            try write(original, service: service, account: account, interactive: true)
            return original
        }
        var result = Data()
        for index in 0..<manifest.count {
            guard let bytes = try helper.read(service: Self.helperVault + ".chunks", account: chunkAccount(account, manifest, index), interactive: false),
                  let decoded = Data(base64Encoded: bytes), decoded.count <= 1024 else { throw ClaudeAccountError.storage }
            result.append(decoded)
        }
        guard SHA256.hash(data: result).map({ String(format: "%02x", $0) }).joined() == manifest.digest else { throw ClaudeAccountError.storage }
        return result
    }
    func write(_ data: Data, service: String, account: String, interactive: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard service == Self.vault else { return try helper.write(data, service: service, account: account, interactive: interactive) }
        guard !data.isEmpty, data.count <= 2_000_000 else { throw ClaudeAccountError.invalidData }
        let old = try manifest(account, interactive: interactive)
        let next = Manifest(version: 1, generation: UUID(), count: (data.count + 1023) / 1024,
                            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        // Failed writes leave the old manifest authoritative; orphaned encrypted
        // chunks are harmless and are never presented as a saved login.
        for index in 0..<next.count {
            let bytes = data.subdata(in: (index * 1024)..<min(data.count, (index + 1) * 1024)).base64EncodedData()
            try helper.write(bytes, service: Self.helperVault + ".chunks", account: chunkAccount(account, next, index), interactive: false)
        }
        try helper.write(JSONEncoder().encode(next), service: Self.helperVault, account: account, interactive: interactive)
        guard try read(service: service, account: account, interactive: false) == data else { throw ClaudeAccountError.storage }
        if let old {
            for index in 0..<old.count {
                try? helper.remove(service: Self.helperVault + ".chunks", account: chunkAccount(account, old, index), interactive: false)
            }
        }
    }
    func remove(service: String, account: String, interactive: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard service == Self.vault else { return try helper.remove(service: service, account: account, interactive: interactive) }
        let old = try manifest(account, interactive: interactive)
        try helper.remove(service: Self.helperVault, account: account, interactive: interactive)
        if let old {
            for index in 0..<old.count {
                try? helper.remove(service: Self.helperVault + ".chunks", account: chunkAccount(account, old, index), interactive: false)
            }
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
