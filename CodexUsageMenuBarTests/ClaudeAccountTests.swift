import Foundation
import XCTest
@testable import CodexUsageMenuBar

final class ClaudeAccountTests: XCTestCase {
    private var paths: ClaudeAccountPaths!
    private var secrets: AccountTestSecrets!
    private var api: AccountTestAPI!
    private var service: ClaudeAccountService!
    private let userA = "11111111-1111-4111-8111-111111111111"
    private let userB = "22222222-2222-4222-8222-222222222222"
    private let org = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        paths = .init(home: root, root: root.appendingPathComponent("native"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        secrets = AccountTestSecrets(); api = AccountTestAPI()
        service = ClaudeAccountService(paths: paths, secrets: secrets, api: api, username: "fixture", validateEnvironment: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: paths.home) }

    private func oauth(_ user: String) -> [String: Any] {
        ["accountUuid": user, "organizationUuid": org, "emailAddress": user == userA ? "a@example.com" : "b@example.com"]
    }
    private func credential(_ token: String, expires: Double = 4_100_000_000_000,
                            extra: [String: Any] = [:]) throws -> Data {
        var data = extra
        data["claudeAiOauth"] = ["accessToken": token, "refreshToken": "fixture-refresh-\(token)", "expiresAt": expires]
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }
    private func setLive(_ user: String, credential: Data) throws {
        let config: [String: Any] = ["oauthAccount": oauth(user), "projects": ["keep": true], "theme": "dark"]
        try ClaudePrivateFile.write(JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), to: paths.config)
        try secrets.write(credential, service: ClaudeAccountService.liveService, account: "fixture", interactive: false)
    }
    private func seedTwoAccounts() async throws -> (ClaudeAccount, ClaudeAccount) {
        try setLive(userB, credential: credential("B", extra: ["mcpOAuth": ["old": "discard"], "trustedDeviceToken": "B-device"]))
        let b = try await service.saveCurrent()
        try setLive(userA, credential: credential("A", extra: ["mcpOAuth": ["fresh": "keep"], "pluginSecrets": ["machine": "keep"], "trustedDeviceToken": "A-device"]))
        let a = try await service.saveCurrent()
        secrets.resetAccessLog()
        return (a, b)
    }

    func testDiscoveryNeverReadsKeychainAndDoesNotTrustCswapActiveSlot() async throws {
        let sequence: [String: Any] = ["activeAccountNumber": 99, "accounts": ["1": ["uuid": userA, "organizationUuid": org, "email": "a@example.com"]]]
        try ClaudePrivateFile.write(JSONSerialization.data(withJSONObject: sequence), to: paths.cswap.appendingPathComponent("sequence.json"))
        let result = try await service.inventory()
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertNil(result.activeID)
        XCTAssertTrue(secrets.accesses.isEmpty)
    }

    func testSwitchPreservesConfigurationAndMachineSecretsAndBacksUpOldAccount() async throws {
        let (a, b) = try await seedTwoAccounts()
        try await service.activate(b.id)
        let result = try await service.inventory()
        XCTAssertEqual(result.activeID, b.id)
        XCTAssertEqual(result.accounts.count, 2)
        let config = try ClaudeSavedLogin.object(ClaudePrivateFile.read(paths.config))
        XCTAssertEqual(config["theme"] as? String, "dark")
        XCTAssertNotNil(config["projects"])
        let live = try XCTUnwrap(secrets.read(service: ClaudeAccountService.liveService, account: "fixture", interactive: false))
        let object = try ClaudeSavedLogin.object(live)
        XCTAssertEqual(object["mcpOAuth"] as? [String: String], ["fresh": "keep"])
        XCTAssertEqual(object["trustedDeviceToken"] as? String, "B-device")
        XCTAssertNotNil(object["pluginSecrets"])
        let old = try XCTUnwrap(secrets.read(service: ClaudeAccountService.vaultService, account: a.id, interactive: false))
        XCTAssertEqual(try JSONDecoder().decode(ClaudeSavedLogin.self, from: old).accessToken(), "A")
        XCTAssertFalse(result.needsRecovery)
        XCTAssertTrue(secrets.accesses.filter { $0.operation == "write" && $0.service == ClaudeAccountService.liveService }.allSatisfy { !$0.interactive })
    }

    func testBackgroundUsageReadsOnlyOwnedKeychainWithoutInteraction() async throws {
        let (a, _) = try await seedTwoAccounts()
        let snapshot = try await service.usage(a.id)
        XCTAssertEqual(snapshot.remainingPercent, 75)
        XCTAssertTrue(secrets.accesses.allSatisfy { !$0.interactive && $0.service == ClaudeAccountService.vaultService })
    }

    func testIdentityMismatchDoesNotWriteLiveState() async throws {
        let (a, b) = try await seedTwoAccounts()
        await api.reject(b.id)
        do { try await service.activate(b.id); XCTFail("must reject wrong identity") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .identityMismatch) }
        let state = try await service.inventory()
        XCTAssertEqual(state.activeID, a.id)
        XCTAssertFalse(secrets.accesses.contains { $0.service == ClaudeAccountService.liveService && $0.operation == "write" })
    }

    func testLiveCredentialChangingDuringVerificationAbortsWithoutOverwrite() async throws {
        let (a, b) = try await seedTwoAccounts()
        let replacement = try credential("new-A")
        await api.onVerify { [secrets] in
            try? secrets?.write(replacement, service: ClaudeAccountService.liveService, account: "fixture", interactive: false)
        }
        do { try await service.activate(b.id); XCTFail("must reject concurrent mutation") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .changed) }
        let state = try await service.inventory()
        XCTAssertEqual(state.activeID, a.id)
        XCTAssertEqual(try secrets.read(service: ClaudeAccountService.liveService, account: "fixture", interactive: false), replacement)
    }

    func testHeldClaudeLockDoesNotGetStolen() async throws {
        let (_, b) = try await seedTwoAccounts()
        let lock = paths.lockDirectories[0]
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        do { try await service.activate(b.id); XCTFail("must respect lock") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .busy) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertFalse(secrets.accesses.contains { $0.operation == "write" && $0.service == ClaudeAccountService.liveService })
    }

    func testFailedLiveWriteRollsBack() async throws {
        let (a, b) = try await seedTwoAccounts()
        secrets.failNextLiveWrites = 1
        do { try await service.activate(b.id); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .rolledBack) }
        let state = try await service.inventory()
        XCTAssertEqual(state.activeID, a.id)
        XCTAssertFalse(state.needsRecovery)
    }

    func testFailedRollbackLeavesRecoveryAndExplicitRestoreWorks() async throws {
        let (a, b) = try await seedTwoAccounts()
        secrets.failNextLiveWrites = 2
        do { try await service.activate(b.id); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .recoveryRequired) }
        var state = try await service.inventory()
        XCTAssertTrue(state.needsRecovery)
        do { _ = try await service.usage(a.id); XCTFail("must block while recovery pending") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .recoveryRequired) }
        try await service.restorePrevious()
        state = try await service.inventory()
        XCTAssertEqual(state.activeID, a.id)
        XCTAssertFalse(state.needsRecovery)
    }

    func testRecoveryNeverOverwritesNewExternalCredentials() async throws {
        let (_, b) = try await seedTwoAccounts()
        secrets.failNextLiveWrites = 2
        try? await service.activate(b.id)
        try secrets.write(credential("external-login"), service: ClaudeAccountService.liveService, account: "fixture", interactive: false)
        do { try await service.restorePrevious(); XCTFail("must preserve external login") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .changed) }
    }

    func testFileFallbackIsNotSilentlyOverwritten() async throws {
        let (_, b) = try await seedTwoAccounts()
        try ClaudePrivateFile.write(credential("file"), to: paths.configHome.appendingPathComponent(".credentials.json"))
        do { try await service.activate(b.id); XCTFail("must not guess active credential backend") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .unsupportedConfiguration) }
    }

    @MainActor
    func testImportCopiesOneAccountAndNotchFollowsWithoutAnotherSelection() async throws {
        try setLive(userB, credential: credential("B"))
        let liveBefore = try Data(contentsOf: paths.config)
        secrets.resetAccessLog()
        let config = try JSONSerialization.data(withJSONObject: ["oauthAccount": oauth(userB)])
        let sequence = try JSONSerialization.data(withJSONObject: ["accounts": ["2": ["uuid": userB, "organizationUuid": org, "email": "b@example.com"]]])
        let sequenceURL = paths.cswap.appendingPathComponent("sequence.json")
        try ClaudePrivateFile.write(sequence, to: sequenceURL)
        try ClaudePrivateFile.write(config, to: paths.cswap.appendingPathComponent("configs/.claude-config-2-b@example.com.json"))
        let backup = try credential("B").base64EncodedData()
        let backupURL = paths.cswap.appendingPathComponent("credentials/.creds-2-b@example.com.enc")
        try ClaudePrivateFile.write(backup, to: backupURL)
        let before = try await service.inventory()
        let controller = ClaudeAccountsController(service: service)
        await controller.importAccount(try XCTUnwrap(before.candidates.first))
        let after = try await service.inventory()
        XCTAssertEqual(after.accounts.count, 1)
        XCTAssertTrue(after.candidates.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sequenceURL), sequence)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
        XCTAssertEqual(try Data(contentsOf: paths.config), liveBefore)
        let snapshot = try await controller.fetchUsage(allowInteraction: false)
        XCTAssertEqual(snapshot.remainingPercent, 75)
        XCTAssertEqual(controller.activeLabel, "b@example.com")
        XCTAssertFalse(secrets.accesses.contains { $0.service == ClaudeAccountService.liveService })
    }

    func testPathTraversalInImportMetadataIsRejected() async throws {
        let sequence: [String: Any] = ["accounts": ["1": ["uuid": userA, "organizationUuid": org, "email": "../../outside"]]]
        try ClaudePrivateFile.write(JSONSerialization.data(withJSONObject: sequence), to: paths.cswap.appendingPathComponent("sequence.json"))
        let result = try await service.inventory()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(secrets.accesses.isEmpty)
    }

    func testSymlinkedPrivateFileRejected() throws {
        let source = paths.home.appendingPathComponent("source")
        let link = paths.home.appendingPathComponent("link")
        try Data("fixture".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try ClaudePrivateFile.read(link))
        XCTAssertThrowsError(try ClaudePrivateFile.write(Data(), to: link))
    }

    func testManifestContainsNoCredentialAndHasPrivatePermissions() async throws {
        _ = try await seedTwoAccounts()
        let data = try Data(contentsOf: paths.manifest)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("accessToken")); XCTAssertFalse(text.contains("refreshToken"))
        let mode = try FileManager.default.attributesOfItem(atPath: paths.manifest.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testUsageParserIdleAndInvalidResponses() throws {
        let snapshot = try ClaudeAccountAPI.decodeUsage(["five_hour": ["utilization": 0.0, "resets_at": NSNull()]])
        XCTAssertTrue(snapshot.isAwaitingFirstMessage)
        XCTAssertEqual(snapshot.remainingPercent, 100)
        let json = Data(#"{"five_hour":{"utilization":0,"resets_at":null}}"#.utf8)
        let decoded = try ClaudeSavedLogin.object(json)
        XCTAssertEqual(try ClaudeAccountAPI.decodeUsage(decoded).remainingPercent, 100)
        for invalid: [String: Any] in [[:], ["five_hour": NSNull()], ["five_hour": ["utilization": 0]],
                                      ["five_hour": ["utilization": true, "resets_at": NSNull()]],
                                      ["five_hour": ["utilization": 101, "resets_at": "2099-01-01T00:00:00Z"]]] {
            XCTAssertThrowsError(try ClaudeAccountAPI.decodeUsage(invalid))
        }
    }

    func testUsageParserDecodesWeeklyAndExplicitlyScopedFable() throws {
        // Shape verified against the installed Claude Code 2.1.300 scoped-limit mapper.
        let json = Data(#"""
        {"five_hour":{"utilization":17,"resets_at":"2099-01-01T00:00:00Z"},
         "seven_day":{"utilization":54,"resets_at":"2099-01-05T00:00:00.123Z"},
         "seven_day_opus":{"utilization":99,"resets_at":"2099-01-05T00:00:00Z"},
         "limits":[{"kind":"weekly_scoped","group":"weekly","percent":72,
                    "resets_at":"2099-01-05T00:00:00Z",
                    "scope":{"model":{"display_name":"Fable"},"surface":null}}]}
        """#.utf8)
        let snapshot = try ClaudeAccountAPI.decodeUsage(ClaudeSavedLogin.object(json))
        XCTAssertEqual(snapshot.version, 4)
        XCTAssertEqual(snapshot.remainingPercent, 83)
        XCTAssertEqual(snapshot.rateLimits.weekly?.remainingPercent, 46)
        XCTAssertEqual(snapshot.rateLimits.fable?.remainingPercent, 28)
        XCTAssertNotEqual(snapshot.resetsAt, snapshot.rateLimits.weekly?.resetsAt)
    }

    func testUsageParserAcceptsModernSessionAndWeeklyRows() throws {
        let value: [String: Any] = ["limits": [
            ["kind": "session", "percent": 8, "resets_at": "2099-01-01T00:00:00Z"],
            ["kind": "weekly_all", "percent": 54, "resets_at": "2099-01-05T00:00:00Z", "scope": NSNull()]
        ]]
        let snapshot = try ClaudeAccountAPI.decodeUsage(value)
        XCTAssertEqual(snapshot.remainingPercent, 92)
        XCTAssertEqual(snapshot.rateLimits.weekly?.remainingPercent, 46)
        XCTAssertNil(snapshot.rateLimits.fable)
    }

    func testFableCannotBeInferredFromAnotherModelOrSurface() throws {
        let valid: [String: Any] = ["utilization": 8, "resets_at": "2099-01-01T00:00:00Z"]
        for scope: [String: Any] in [
            ["model": ["display_name": "Opus"]],
            ["model": ["display_name": "Fable"], "surface": ["display_name": "Cowork"]],
            ["surface": ["display_name": "Fable"]]
        ] {
            let snapshot = try ClaudeAccountAPI.decodeUsage([
                "five_hour": valid, "seven_day_opus": valid, "seven_day_omelette": valid,
                "limits": [["kind": "weekly_scoped", "percent": 80,
                            "resets_at": "2099-01-05T00:00:00Z", "scope": scope]]
            ])
            XCTAssertNil(snapshot.rateLimits.fable)
        }
    }

    func testMissingAndMalformedOptionalLimitsLeaveFiveHourIntact() throws {
        for invalid: Any in [NSNull(), ["utilization": true, "resets_at": NSNull()],
                             ["utilization": 101, "resets_at": "2099-01-01T00:00:00Z"],
                             ["utilization": 5, "resets_at": NSNull()],
                             ["utilization": 0], ["utilization": 0, "resets_at": "2000-01-01T00:00:00Z"]] {
            let snapshot = try ClaudeAccountAPI.decodeUsage([
                "five_hour": ["utilization": 0, "resets_at": NSNull()], "seven_day": invalid,
                "limits": [["kind": "weekly_scoped", "percent": true, "resets_at": NSNull(),
                            "scope": ["model": ["display_name": "Fable"]]]]
            ])
            XCTAssertEqual(snapshot.remainingPercent, 100)
            XCTAssertNil(snapshot.rateLimits.weekly)
            XCTAssertNil(snapshot.rateLimits.fable)
        }
    }

    func testZeroExplicitNullResetIsIdleForWeeklyAndFable() throws {
        let snapshot = try ClaudeAccountAPI.decodeUsage([
            "seven_day": ["utilization": 0, "resets_at": NSNull()],
            "limits": [["kind": "weekly_scoped", "percent": 0, "resets_at": NSNull(),
                        "scope": ["model": ["display_name": "fable"]]]]
        ])
        XCTAssertNil(snapshot.remainingPercent)
        XCTAssertEqual(snapshot.rateLimits.weekly?.remainingPercent, 100)
        XCTAssertTrue(snapshot.rateLimits.fable?.isAwaitingFirstMessage == true)
    }

    func testDuplicateFableRowsAreUnavailableInsteadOfArbitrarilyChosen() throws {
        let row: [String: Any] = ["kind": "weekly_scoped", "percent": 10,
            "resets_at": "2099-01-01T00:00:00Z", "scope": ["model": ["display_name": "Fable"]]]
        let snapshot = try ClaudeAccountAPI.decodeUsage([
            "five_hour": ["utilization": 0, "resets_at": NSNull()], "limits": [row, row]
        ])
        XCTAssertNil(snapshot.rateLimits.fable)
    }

    func testModernInvalidRowDoesNotFallBackToLegacyFullAllowance() throws {
        let snapshot = try ClaudeAccountAPI.decodeUsage([
            "five_hour": ["utilization": 0, "resets_at": NSNull()],
            "seven_day": ["utilization": 0, "resets_at": NSNull()],
            "limits": [["kind": "weekly_all", "percent": true, "resets_at": NSNull()]]
        ])
        XCTAssertNil(snapshot.rateLimits.weekly)
    }

    func testDistinctOrganizationsAreDifferentAccounts() throws {
        let first = try ClaudeAccount(oauth: oauth(userA))
        var other = oauth(userA); other["organizationUuid"] = userB
        XCTAssertNotEqual(first.id, try ClaudeAccount(oauth: other).id)
    }

    func testNativeAPIUsesVerifiedIdentityAndDecodesActualJSONNumbers() async throws {
        let login = try ClaudeSavedLogin(oauthAccount: oauth(userA), credentials: credential("fixture-token"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPFixture.self]
        AccountHTTPFixture.route { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            if request.url?.path == "/api/oauth/profile" {
                return (200, ["account": ["uuid": login.account.userID], "organization": ["uuid": login.account.organizationID]])
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (200, ["five_hour": ["utilization": 0, "resets_at": NSNull()]])
        }
        let client = ClaudeAccountAPI(configuration: configuration)
        let result = try await client.usage(login)
        XCTAssertEqual(result.remainingPercent, 100)
        XCTAssertEqual(AccountHTTPFixture.requestCount, 2)
    }

    func testNativeAPIWrongIdentityStopsBeforeUsageRequest() async throws {
        let login = try ClaudeSavedLogin(oauthAccount: oauth(userA), credentials: credential("fixture-token"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPFixture.self]
        AccountHTTPFixture.route { _ in (200, ["account": ["uuid": "wrong-user"], "organization": ["uuid": "wrong-org"]]) }
        let client = ClaudeAccountAPI(configuration: configuration)
        do { _ = try await client.usage(login); XCTFail("must reject wrong identity") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .identityMismatch) }
        XCTAssertEqual(AccountHTTPFixture.requestCount, 1)
    }

    func testNativeAPIRateLimitBacksOffWithoutRetryingAnotherAccount() async throws {
        let login = try ClaudeSavedLogin(oauthAccount: oauth(userA), credentials: credential("fixture-token"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPFixture.self]
        AccountHTTPFixture.route { _ in (429, ["private_detail": "must-not-be-displayed"]) }
        let client = ClaudeAccountAPI(configuration: configuration)
        for _ in 0..<2 {
            do { _ = try await client.usage(login); XCTFail("must fail safely") }
            catch { XCTAssertEqual(error as? ClaudeAccountError, .rateLimited) }
        }
        XCTAssertEqual(AccountHTTPFixture.requestCount, 1)
    }

    func testNativeAPIDenialDoesNotExposeResponseBody() async throws {
        let login = try ClaudeSavedLogin(oauthAccount: oauth(userA), credentials: credential("fixture-token"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPFixture.self]
        AccountHTTPFixture.route { _ in (403, ["private_detail": "must-not-be-displayed"]) }
        let client = ClaudeAccountAPI(configuration: configuration)
        do { _ = try await client.usage(login); XCTFail("must fail safely") }
        catch {
            XCTAssertEqual(error as? ClaudeAccountError, .denied(403))
            XCTAssertFalse(error.localizedDescription.contains("must-not-be-displayed"))
        }
    }

    func testManagedOrganizationRestrictionStopsBeforeLiveMutation() async throws {
        let (_, b) = try await seedTwoAccounts()
        try ClaudePrivateFile.write(JSONSerialization.data(withJSONObject: ["forceLoginOrgUUID": userA]), to: paths.configHome.appendingPathComponent("settings.json"))
        do { try await service.activate(b.id); XCTFail("must respect organization policy") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .unsupportedConfiguration) }
        XCTAssertFalse(secrets.accesses.contains { $0.service == ClaudeAccountService.liveService })
    }

    func testIncompleteCswapAccountIsVisibleButNotImportable() async throws {
        let value: [String: Any] = ["accounts": ["4": ["email": "api-key-entry", "uuid": "", "organizationUuid": ""]]]
        try ClaudePrivateFile.write(JSONSerialization.data(withJSONObject: value), to: paths.cswap.appendingPathComponent("sequence.json"))
        let result = try await service.inventory()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.unavailableAccounts, ["api-key-entry"])
    }

    func testExpiredSavedTokenIsNotRenewedByBackgroundChecks() async throws {
        try setLive(userA, credential: credential("A", expires: 1))
        let account = try await service.saveCurrent()
        secrets.resetAccessLog()
        do { _ = try await service.usage(account.id); XCTFail("expired usage must be unavailable") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .activeLoginNeedsSync) }
        let renewals = await api.renewals
        XCTAssertEqual(renewals, 0)
        XCTAssertTrue(secrets.accesses.allSatisfy { $0.operation == "read" && !$0.interactive && $0.service == ClaudeAccountService.vaultService })
    }

    func testExplicitSwitchRenewsExpiredTargetAndStoresNewCredential() async throws {
        try setLive(userB, credential: credential("B", expires: 1))
        let b = try await service.saveCurrent()
        try setLive(userA, credential: credential("A"))
        _ = try await service.saveCurrent()
        try await service.activate(b.id)
        let renewals = await api.renewals
        XCTAssertEqual(renewals, 1)
        let data = try XCTUnwrap(secrets.read(service: ClaudeAccountService.vaultService, account: b.id, interactive: false))
        let login = try JSONDecoder().decode(ClaudeSavedLogin.self, from: data)
        XCTAssertEqual(try login.accessToken(), "renewed-fixture")
    }

    @MainActor
    func testNotchImmediatelyUsesActiveSavedAccountWithoutSourceSelection() async throws {
        let (a, b) = try await seedTwoAccounts()
        await api.setUsage(8, for: a.id)
        await api.setUsage(0, for: b.id)
        let controller = ClaudeAccountsController(service: service)
        let result = try await controller.fetchUsage(allowInteraction: false)
        XCTAssertEqual(result.remainingPercent, 92)
        XCTAssertEqual(controller.activeID, a.id)
        XCTAssertEqual(controller.activeLabel, a.email)
        XCTAssertEqual(controller.usageByID[a.id], result)
        XCTAssertNil(controller.usageByID[b.id])
        XCTAssertTrue(secrets.accesses.allSatisfy { $0.operation == "read" && !$0.interactive && $0.service == ClaudeAccountService.vaultService })
    }

    @MainActor
    func testUnsavedActiveAccountDoesNotFallBackToAnotherSavedAccount() async throws {
        try setLive(userB, credential: credential("B"))
        _ = try await service.saveCurrent()
        try setLive(userA, credential: credential("A"))
        secrets.resetAccessLog()
        let controller = ClaudeAccountsController(service: service)
        do { _ = try await controller.fetchUsage(allowInteraction: false); XCTFail("must require the active account to be saved") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .noLogin) }
        XCTAssertTrue(controller.usageByID.isEmpty)
        XCTAssertTrue(secrets.accesses.isEmpty)
    }

    @MainActor
    func testNotchAutomaticallyFollowsExternalAccountSwitchOnNextRefresh() async throws {
        let (a, b) = try await seedTwoAccounts()
        await api.setUsage(8, for: a.id)
        await api.setUsage(54, for: b.id)
        let controller = ClaudeAccountsController(service: service)
        let store = ClaudeUsageStore(monitor: false, provider: controller)
        await store.refreshFromAccount()
        XCTAssertEqual(store.snapshot?.remainingPercent, 92)
        try setLive(userB, credential: credential("B"))
        await store.refreshFromAccount()
        XCTAssertEqual(store.snapshot?.remainingPercent, 46)
        XCTAssertEqual(store.activeAccountLabel, b.email)
    }

    @MainActor
    func testExpiredActiveSavedLoginClearsBothNotchAndAccountPercentageWithoutPrompting() async throws {
        let (a, _) = try await seedTwoAccounts()
        let controller = ClaudeAccountsController(service: service)
        let store = ClaudeUsageStore(monitor: false, provider: controller)
        await store.refreshFromAccount()
        XCTAssertNotNil(store.snapshot)
        await api.failUsage(.expired)
        secrets.resetAccessLog()
        await store.refreshFromAccount(allowInteraction: true)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(controller.usageByID[a.id])
        XCTAssertEqual(store.errorMessage, ClaudeAccountError.activeLoginNeedsSync.errorDescription)
        let renewals = await api.renewals
        XCTAssertEqual(renewals, 0)
        XCTAssertTrue(secrets.accesses.allSatisfy { $0.operation == "read" && !$0.interactive && $0.service == ClaudeAccountService.vaultService })
    }

    func testInactiveExpiredAccountStillRequiresExplicitSwitchToRenew() async throws {
        let (_, b) = try await seedTwoAccounts()
        await api.failUsage(.expired)
        do { _ = try await service.usage(b.id); XCTFail("expired inactive account must not renew silently") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .expired) }
        let renewals = await api.renewals
        XCTAssertEqual(renewals, 0)
    }

    func testActiveRejectedTokenRequestsSyncButPolicyDenialDoesNotRequestLogin() async throws {
        let (a, _) = try await seedTwoAccounts()
        await api.failUsage(.denied(401))
        do { _ = try await service.usage(a.id); XCTFail("must request sync") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .activeLoginNeedsSync) }
        await api.failUsage(.denied(403))
        do { _ = try await service.usage(a.id); XCTFail("must preserve denial") }
        catch { XCTAssertEqual(error as? ClaudeAccountError, .denied(403)) }
    }

    @MainActor
    func testExternalSwitchDuringUsageDropsTheOldAccountResult() async throws {
        let (_, b) = try await seedTwoAccounts()
        let newConfig = try JSONSerialization.data(withJSONObject: ["oauthAccount": oauth(userB)])
        let config = paths.config
        await api.onVerify { try? ClaudePrivateFile.write(newConfig, to: config) }
        let controller = ClaudeAccountsController(service: service)
        do { _ = try await controller.fetchUsage(allowInteraction: false); XCTFail("must drop old account usage") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(controller.activeID, b.id)
    }
}

private final class AccountHTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, [String: Any]))?
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func route(_ handler: @escaping (URLRequest) -> (Int, [String: Any])) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let route = Self.handler; Self.count += 1; Self.lock.unlock()
        guard let route, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let (status, body) = route(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AccountTestSecrets: ClaudeSecretStoring, @unchecked Sendable {
    struct Access { let operation: String; let service: String; let interactive: Bool }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var accesses: [Access] = []
    var failNextLiveWrites = 0
    func resetAccessLog() { lock.lock(); defer { lock.unlock() }; accesses = [] }
    func read(service: String, account: String, interactive: Bool) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        accesses.append(.init(operation: "read", service: service, interactive: interactive))
        return values[service + "/" + account]
    }
    func write(_ data: Data, service: String, account: String, interactive: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        accesses.append(.init(operation: "write", service: service, interactive: interactive))
        if service == ClaudeAccountService.liveService, failNextLiveWrites > 0 {
            failNextLiveWrites -= 1; throw ClaudeAccountError.keychainAuthorization
        }
        values[service + "/" + account] = data
    }
    func remove(service: String, account: String, interactive: Bool) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: service + "/" + account)
    }
}

private actor AccountTestAPI: ClaudeAccountNetworking {
    private(set) var renewals = 0
    private var rejectID: String?
    private var callback: (@Sendable () -> Void)?
    private var usageByID: [String: Double] = [:]
    private var usageError: ClaudeAccountError?
    func setUsage(_ used: Double, for id: String) { usageByID[id] = used }
    func failUsage(_ error: ClaudeAccountError) { usageError = error }
    func reject(_ id: String) { rejectID = id }
    func onVerify(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func verify(_ login: ClaudeSavedLogin) throws {
        if login.account.id == rejectID { throw ClaudeAccountError.identityMismatch }
        callback?()
    }
    func renew(_ login: ClaudeSavedLogin) throws -> ClaudeSavedLogin {
        renewals += 1
        var copy = login
        copy.credentials = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "renewed-fixture", "expiresAt": 4_100_000_000_000.0]])
        return copy
    }
    func usage(_ login: ClaudeSavedLogin) throws -> ClaudeUsageSnapshot {
        if let usageError { throw usageError }
        guard !login.expiresSoon else { throw ClaudeAccountError.expired }
        try verify(login)
        return .init(version: 3, updatedAt: Date(), rateLimits: .init(fiveHour: .init(usedPercentage: usageByID[login.account.id] ?? 25, resetsAt: Date().addingTimeInterval(3600))))
    }
}
