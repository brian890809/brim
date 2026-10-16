import AppKit
import SwiftUI

@MainActor
final class ClaudeAccountsController: ObservableObject, ClaudeUsageProviding {
    static let shared = ClaudeAccountsController()
    @Published private(set) var accounts: [ClaudeAccount] = []
    @Published private(set) var candidates: [ClaudeImportCandidate] = []
    @Published private(set) var unavailableAccounts: [String] = []
    @Published private(set) var activeID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var message: String?
    @Published private(set) var usageByID: [String: ClaudeUsageSnapshot] = [:]
    @Published private(set) var errorsByID: [String: String] = [:]
    var onRefresh: (() -> Void)?
    var onIdentityChanged: (() -> Void)?
    private let service: any ClaudeAccountsProviding
    private var window: NSWindow?
    private var generation = 0

    init(service: any ClaudeAccountsProviding = ClaudeAccountService()) {
        // The default Claude Code identity is the sole usage source. Older web
        // session preferences are deliberately ignored, never used as fallback.
        self.service = service
    }

    var activeLabel: String? { accounts.first(where: { $0.id == activeID })?.email }

    private func invalidate() { generation += 1; onIdentityChanged?() }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Claude Accounts — Brim"
            window.minSize = NSSize(width: 650, height: 460)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ClaudeAccountsView(controller: self))
            window.center(); self.window = window; window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { await reload() }
    }

    private func updateInventory() async throws {
        let result = try await service.inventory()
        if activeID != result.activeID { activeID = result.activeID; invalidate() }
        accounts = result.accounts; candidates = result.candidates; needsRecovery = result.needsRecovery
        unavailableAccounts = result.unavailableAccounts
    }

    func reload() async {
        guard !isWorking else { return }
        do { try await updateInventory() }
        catch { message = Self.safeMessage(error) }
    }

    func importAccount(_ candidate: ClaudeImportCandidate) async {
        await perform {
            try await self.service.importAccount(candidate)
            self.message = "Imported. The notch automatically shows the active Claude Code account. The cswap original is unchanged."
        }
    }

    func saveCurrent() async {
        await perform {
            _ = try await self.service.saveCurrent()
            self.message = "Saved the current Claude Code login. The notch follows this account automatically."
        }
    }

    func activate(_ account: ClaudeAccount) async {
        await perform {
            // Clear the old percentage before starting, even if the switch fails.
            self.invalidate()
            try await self.service.activate(account.id)
            try await self.updateInventory()
            guard self.activeID == account.id else { throw ClaudeAccountError.changed }
            self.message = "Default Claude Code login switched. Restart existing chats or the VS Code Claude extension to use it immediately. Isolated profiles are unchanged."
        }
    }

    func recover() async {
        await perform {
            self.invalidate()
            try await self.service.restorePrevious()
            self.message = "Previous Claude Code login restored."
        }
    }

    func authorizeActiveLogin(_ account: ClaudeAccount) async {
        await perform {
            try await self.service.authorizeActiveLogin(account.id)
            self.message = "System-helper storage is ready for \(account.email). Other saved accounts were not requested."
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true; message = nil
        do { try await action() }
        catch { message = Self.safeMessage(error) }
        do { try await updateInventory() }
        catch { message = Self.safeMessage(error) }
        isWorking = false
        onRefresh?()
    }

    func refreshAccounts() async {
        guard !isWorking else { return }
        isWorking = true; message = nil
        defer { isWorking = false }
        do { try await updateInventory() } catch { message = Self.safeMessage(error); return }
        for account in accounts {
            if Task.isCancelled { return }
            do {
                usageByID[account.id] = try await service.usage(account.id)
                errorsByID[account.id] = nil
            } catch {
                usageByID[account.id] = nil
                errorsByID[account.id] = Self.safeMessage(error)
                if (error as? ClaudeAccountError) == .rateLimited { break }
            }
        }
    }

    func fetchUsage(allowInteraction: Bool) async throws -> ClaudeUsageSnapshot {
        guard !isWorking else { throw CancellationError() }
        try await updateInventory()
        guard let id = activeID, accounts.contains(where: { $0.id == id }) else { throw ClaudeAccountError.noLogin }
        let token = generation
        let result: ClaudeUsageSnapshot
        do { result = try await service.usage(id) }
        catch {
            try await updateInventory()
            guard token == generation, id == activeID else { throw CancellationError() }
            usageByID[id] = nil
            errorsByID[id] = Self.safeMessage(error)
            throw error
        }
        // An external cswap/login can change the default during the network call.
        try await updateInventory()
        guard token == generation, id == activeID else { throw CancellationError() }
        usageByID[id] = result; errorsByID[id] = nil
        return result
    }

    static func safeMessage(_ error: Error) -> String {
        (error as? ClaudeAccountError)?.errorDescription ?? "The account operation could not be completed."
    }
}

struct ClaudeAccountsView: View {
    @ObservedObject var controller: ClaudeAccountsController
    @State private var pendingSwitch: ClaudeAccount?
    @State private var pendingImport: ClaudeImportCandidate?
    @State private var confirmSave = false
    @State private var pendingAuthorization: ClaudeAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = controller.message { Text(message).font(.callout).textSelection(.enabled) }
            if controller.needsRecovery {
                HStack {
                    Label("An interrupted switch needs recovery.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Restore previous login") { Task { await controller.recover() } }
                }.foregroundStyle(.orange)
            }
            List {
                Section("Saved in Brim") {
                    if controller.accounts.isEmpty {
                        Text("Save your current Claude Code login or import an account below.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(controller.accounts) { account in
                        ClaudeAccountRow(account: account, isActive: controller.activeID == account.id,
                            snapshot: controller.usageByID[account.id], error: controller.errorsByID[account.id]) {
                            pendingSwitch = account
                        }
                    }
                }
                if !controller.candidates.isEmpty {
                    Section("Available to import from cswap") {
                        ForEach(controller.candidates) { candidate in
                            HStack {
                                identity(candidate.account)
                                Spacer()
                                Button("Import") { pendingImport = candidate }
                            }.padding(.vertical, 6)
                        }
                    }
                }
                if !controller.unavailableAccounts.isEmpty {
                    Section("cswap entries needing a new sign-in") {
                        ForEach(Array(controller.unavailableAccounts.enumerated()), id: \.offset) { _, label in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label)
                                Text("Missing subscription identity or an API-key entry. For a subscription, sign in with Claude Code and use Save current login.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }.listStyle(.inset)
            footer
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 400)
        .disabled(controller.isWorking)
        .overlay(alignment: .topTrailing) {
            if controller.isWorking { ProgressView().controlSize(.small).padding(28).accessibilityLabel("Updating Claude accounts") }
        }
        .confirmationDialog("Switch the default Claude Code subscription?", isPresented: Binding(
            get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }
        ), titleVisibility: .visible) {
            if let account = pendingSwitch {
                Button("Set active: \(account.email)") { Task { await controller.activate(account) }; pendingSwitch = nil }
            }
            Button("Cancel", role: .cancel) { pendingSwitch = nil }
        } message: {
            Text("The previous login is saved before replacement. Existing chats may need a restart. Stop other account switchers and sessions using this account in isolated profiles first. This does not change Claude Desktop or browser sign-ins.")
        }
        .confirmationDialog("Import this saved Claude sign-in?", isPresented: Binding(
            get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }
        ), titleVisibility: .visible) {
            if let candidate = pendingImport {
                Button("Import \(candidate.account.email)") { Task { await controller.importAccount(candidate) }; pendingImport = nil }
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Copies this account's credentials into Brim's Keychain storage. macOS may ask for permission. cswap's files and the active Claude Code login are not changed.")
        }
        .confirmationDialog("Save the current Claude Code sign-in?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save current login") { Task { await controller.saveCurrent() } }
        } message: {
            Text("Apple's security tool reads Claude Code-credentials, verifies the current account, and updates its saved copy in Keychain. If the saved copy needs migration, use Allow active account first. No credentials are stored in plaintext files. macOS may ask you to authorize the security tool.")
        }
        .confirmationDialog("Allow access to this saved login?", isPresented: Binding(
            get: { pendingAuthorization != nil }, set: { if !$0 { pendingAuthorization = nil } }
        ), titleVisibility: .visible) {
            if let account = pendingAuthorization {
                Button("Allow \(account.email)") {
                    Task { await controller.authorizeActiveLogin(account) }
                    pendingAuthorization = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingAuthorization = nil }
        } message: {
            Text("Migrates only this account's old saved login into Keychain storage owned by Apple's security tool, retaining the old item. Future app updates use that same tool. This trusts the system tool, not exclusively Brim. It does not read Claude Code-credentials or other saved accounts. macOS may request permission; a locked Keychain can still require unlocking.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Claude accounts").font(.title2.bold())
            Text("Choose which subscription the default Claude Code login uses.").foregroundStyle(.secondary)
            HStack {
                Button("Save current login…") { confirmSave = true }
                Button("Check usage") { Task { await controller.refreshAccounts() } }
                Button("Reload list") { Task { await controller.reload() } }
                if let active = controller.accounts.first(where: { $0.id == controller.activeID }) {
                    Button("Allow active account…") { pendingAuthorization = active }
                        .help("Authorize only the saved login for \(active.email), not every saved account")
                }
            }.padding(.top, 4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The notch automatically follows the active Claude Code account.", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
            Text("No separate web sign-in. Expired active logins sync from Claude Code when helper access is authorized. Background checks pause if the Keychain is locked or access cannot be verified; they never renew tokens. A lock or permission change during access can still need approval. Inactive logins renew only when you choose Set active.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func identity(_ account: ClaudeAccount) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.email).fontWeight(.medium)
            Text(account.organizationName.isEmpty ? "Personal subscription" : account.organizationName)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ClaudeAccountRow: View {
    let account: ClaudeAccount
    let isActive: Bool
    let snapshot: ClaudeUsageSnapshot?
    let error: String?
    let onSwitch: () -> Void
    private var fiveHour: ClaudeUsageSnapshot.UsageWindow? { snapshot?.window(for: .fiveHour) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email).fontWeight(.medium)
                    Text(account.organizationName.isEmpty ? "Personal subscription" : account.organizationName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let percent = fiveHour?.remainingPercent {
                    Text("\(percent)% left").monospacedDigit()
                        .accessibilityLabel("\(percent) percent of five-hour allowance remaining")
                }
                if isActive { Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Set active…", action: onSwitch) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            else if let snapshot {
                Text(fiveHour?.isAwaitingFirstMessage == true ? "Starts with your first message" :
                    "Resets \(fiveHour?.resetsAt?.formatted(date: .omitted, time: .shortened) ?? "—") · Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

#Preview("Saved account row") {
    ClaudeAccountRow(account: .init(userID: "fixture", organizationID: "personal", email: "personal@example.com"),
        isActive: true, snapshot: .init(version: 3, updatedAt: Date(), rateLimits: .init(fiveHour: .init(
            usedPercentage: 26, resetsAt: Date().addingTimeInterval(3600)))), error: nil, onSwitch: {})
        .padding().frame(width: 600)
}

#Preview("Account needs renewal") {
    ClaudeAccountRow(account: .init(userID: "fixture", organizationID: "work", email: "work@example.com", organizationName: "Work"),
        isActive: false, snapshot: nil, error: ClaudeAccountError.expired.errorDescription, onSwitch: {})
        .padding().frame(width: 600)
}

#if DEBUG
/// Launch with -PreviewClaudeAccounts YES. This fixture never contacts Keychain,
/// provider APIs, cswap files, or the user's active Claude login.
actor PreviewClaudeAccounts: ClaudeAccountsProviding {
    private let personal = ClaudeAccount(userID: "personal", organizationID: "personal", email: "personal@example.com", organizationName: "Personal · Max")
    private let work = ClaudeAccount(userID: "work", organizationID: "work", email: "work@example.com", organizationName: "Work · Pro")
    func inventory() -> ClaudeAccountInventory {
        .init(accounts: [personal, work], candidates: [.init(slot: "3", account: .init(userID: "other", organizationID: "other", email: "another@example.com"))],
              activeID: personal.id, needsRecovery: false, unavailableAccounts: ["API-key entry"])
    }
    func importAccount(_ candidate: ClaudeImportCandidate) throws { throw ClaudeAccountError.unsupportedConfiguration }
    func saveCurrent() throws -> ClaudeAccount { throw ClaudeAccountError.unsupportedConfiguration }
    func activate(_ id: String) throws { throw ClaudeAccountError.unsupportedConfiguration }
    func restorePrevious() throws { throw ClaudeAccountError.unsupportedConfiguration }
    func authorizeActiveLogin(_ id: String) {}
    func usage(_ id: String) -> ClaudeUsageSnapshot {
        .init(version: 3, updatedAt: Date(), rateLimits: .init(fiveHour: .init(usedPercentage: id == personal.id ? 26 : 65, resetsAt: Date().addingTimeInterval(3600))))
    }
}
#endif
