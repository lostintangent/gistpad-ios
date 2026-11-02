import Auth
import Foundation
import Security
import Synchronization
import Testing
@testable import GistPadSync

private let testAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!

private func authUser(metadata: [String: Any] = ["user_name": "test-user", "sub": "42"]) -> [String: Any] {
    [
        "id": testAccountID.uuidString,
        "aud": "authenticated",
        "created_at": "2026-10-23T20:00:00Z",
        "updated_at": "2026-10-23T20:00:00Z",
        "app_metadata": ["provider": "github"],
        "user_metadata": metadata
    ]
}

private func authSession(includeProvider: Bool = true) throws -> Data {
    var body: [String: Any] = [
        "access_token": "fake-access",
        "refresh_token": "fake-refresh",
        "token_type": "bearer", "expires_in": 3600, "expires_at": 4_102_444_800,
        "user": authUser()
    ]
    if includeProvider { body["provider_token"] = "fake-github" }
    return try JSONSerialization.data(withJSONObject: body)
}

private final class ProviderRemovalFailureCredentials: AccountCredentialStorage, Sendable {
    let memory = MemoryCredentials()
    let failsProviderRemoval = Mutex(false)

    func store(key: String, value: Data) throws { try memory.store(key: key, value: value) }
    func retrieve(key: String) throws -> Data? { try memory.retrieve(key: key) }
    func remove(key: String) throws {
        if key.hasPrefix("github-provider-"), failsProviderRemoval.withLock({ $0 }) {
            throw AccountError.keychain(-25308)
        }
        try memory.remove(key: key)
    }
    func keys(withPrefix prefix: String) throws -> [String] { try memory.keys(withPrefix: prefix) }
    func upgradeAccessibility() throws {}
}

// Signs in through the fake so the account, connection, and session are all persisted. Writes return `update`.
private func signedInAccount(
    credentials: any AccountCredentialStorage, update: FakeResponse = FakeResponse()
) async throws -> AccountService {
    let userData = try JSONSerialization.data(withJSONObject: authUser())
    let sessionData = try authSession()
    let account = try AccountService(
        publishableKey: "sb_publishable_fake", credentials: credentials,
        session: FakeURLProtocol.session { request in
            if request.httpMethod == "PUT" { return update }
            if request.url?.path.hasSuffix("/user") == true { return FakeResponse(data: userData) }
            return FakeResponse(data: sessionData)
        },
        automaticallyRefreshesToken: false
    )
    _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
    return account
}

@Suite struct AccountTests {
    @Test(arguments: [200, 400])
    func signOutBlocksCachedRestorationAndClearsBothCredentialsAfterSuspension(status: Int) async throws {
        let credentials = MemoryCredentials()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (permitted, permit) = AsyncStream<Void>.makeStream()
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { request in
                if request.url?.path.hasSuffix("/logout") == true {
                    #expect(request.url?.query == "scope=local")
                    start.yield(())
                    for await _ in permitted { break }
                    return FakeResponse(status: status)
                }
                return FakeResponse(data: try authSession())
            },
            automaticallyRefreshesToken: false)
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        let key = "github-provider-\(testAccountID.uuidString)"
        let savedSession = try credentials.retrieve(key: "gistpad-supabase-session")
        let session = try #require(savedSession)
        let signingOut = Task { try await account.signOut(accountID: testAccountID) }
        for await _ in started { break }
        try credentials.store(key: "gistpad-supabase-session", value: session)
        #expect(try credentials.retrieve(key: key) == nil)
        await #expect(throws: AccountError.signInInProgress) { try await account.cachedAccount() }
        #expect(try credentials.retrieve(key: key) == nil)
        try credentials.store(key: key, value: Data("late-fake-provider".utf8))
        permit.yield(())
        if status == 200 {
            try await signingOut.value
        } else {
            await #expect(throws: (any Error).self) { try await signingOut.value }
        }
        #expect(try credentials.retrieve(key: key) == nil)
        #expect(try credentials.retrieve(key: "gistpad-supabase-session") == nil)
        #expect(try await account.cachedAccount() == nil)
        await #expect(throws: AccountError.signedOut) {
            try await account.githubToken(accountID: testAccountID)
        }
        let reopened = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            automaticallyRefreshesToken: false)
        #expect(try await reopened.cachedAccount() == nil)
    }

    @Test func finalProviderCleanupFailureStillRemovesTheLocalSessionAndSurfacesTheError() async throws {
        let credentials = ProviderRemovalFailureCredentials()
        let persisted = Mutex<Data?>(nil)
        let providerKey = "github-provider-\(testAccountID.uuidString)"
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { request in
                if request.url?.path.hasSuffix("/logout") == true {
                    let session = try #require(persisted.withLock { $0 })
                    try credentials.store(key: "gistpad-supabase-session", value: session)
                    try credentials.store(key: providerKey, value: Data("late-fake-provider".utf8))
                    credentials.failsProviderRemoval.withLock { $0 = true }
                    return FakeResponse()
                }
                return FakeResponse(data: try authSession())
            },
            automaticallyRefreshesToken: false)
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        let savedSession = try credentials.retrieve(key: "gistpad-supabase-session")
        let session = try #require(savedSession)
        persisted.withLock { $0 = session }
        await #expect(throws: AccountError.keychain(-25308)) {
            try await account.signOut(accountID: testAccountID)
        }
        #expect(try credentials.retrieve(key: "gistpad-supabase-session") == nil)
        #expect(try await account.cachedAccount() == nil)
        #expect(try credentials.retrieve(key: providerKey) != nil)
    }

    @Test func pkceRequestsGistScopeAndPersistsProviderAcrossRefreshAndRelaunch() async throws {
        let credentials = MemoryCredentials()
        let exchanges = Mutex(0)
        let session = FakeURLProtocol.session { request in
            #expect(request.url?.host == "upnfachynwuwialgybvf.supabase.co")
            if request.url?.path.hasSuffix("/token") == true {
                let body = try requestBody(request)
                #expect(body["auth_code"] as? String == "fake-code")
                #expect(!(body["code_verifier"] as? String ?? "").isEmpty)
                exchanges.withLock { $0 += 1 }
                return FakeResponse(data: try authSession())
            }
            return FakeResponse(data: try JSONSerialization.data(withJSONObject: authUser()))
        }
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: session, automaticallyRefreshesToken: false
        )
        let result = try await account.signIn { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.first { $0.name == "provider" }?.value == "github")
            #expect(query.first { $0.name == "scopes" }?.value == "gist")
            #expect(query.first { $0.name == "redirect_to" }?.value == "gistpad://auth-callback")
            #expect(query.first { $0.name == "code_challenge_method" }?.value == "s256")
            let challenge = query.first { $0.name == "code_challenge" }?.value ?? ""
            #expect(!challenge.isEmpty)
            return URL(string: "gistpad://auth-callback?code=fake-code")!
        }
        #expect(result.id == testAccountID)
        #expect(result.githubUserID == 42)
        #expect(try await account.githubToken(accountID: result.id) == "fake-github")
        // Supabase refreshes do not resend the GitHub provider token.
        let storedData = try credentials.retrieve(key: "gistpad-supabase-session")
        let original = try #require(storedData)
        var stored = try JSONDecoder().decode(Session.self, from: original)
        stored.providerToken = nil
        try credentials.store(key: "gistpad-supabase-session", value: JSONEncoder().encode(stored))
        let restored = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: session, automaticallyRefreshesToken: false
        )
        #expect(try await restored.cachedAccount()?.id == result.id)
        #expect(try await restored.githubToken(accountID: result.id) == "fake-github")
        #expect(exchanges.withLock { $0 } == 1)
        await #expect(throws: AccountError.accountChanged) {
            try await restored.githubToken(accountID: UUID())
        }
    }

    @Test func storageUsesSupabaseAccessTokenAndRejectsUseAfterSignOut() async throws {
        let credentials = MemoryCredentials()
        let calls = Mutex(0)
        let bytes = Data("fake image transfer".utf8)
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { request in
                if request.url?.path().hasPrefix("/auth/") == true { return FakeResponse(data: try authSession()) }
                calls.withLock { $0 += 1 }
                if request.httpMethod == "POST" {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access")
                    return FakeResponse()
                }
                return FakeResponse(data: bytes)
            },
            automaticallyRefreshesToken: false
        )
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        let storage = try await account.imageStorageClient(accountID: testAccountID)
        _ = try await storage.upload(bytes, gistID: "abc123", assetID: UUID())
        try credentials.remove(key: "gistpad-supabase-session")
        await #expect(throws: AccountError.signedOut) {
            try await storage.upload(bytes, gistID: "abc123", assetID: UUID())
        }
        #expect(calls.withLock { $0 } == 2)
        let foreign = try await account.imageStorageClient(accountID: UUID())
        await #expect(throws: AccountError.signedOut) {
            try await foreign.upload(bytes, gistID: "abc123", assetID: UUID())
        }
    }

    @Test func rejectsServiceRoleConfiguration() {
        #expect(throws: AccountError.invalidConfiguration) {
            try AccountService(publishableKey: "eyJ.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.fake")
        }
    }

    @Test func cancellationDoesNotCreateAnAccount() async throws {
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: MemoryCredentials(),
            session: FakeURLProtocol.session { _ in
                Issue.record("Cancelled sign-in must not exchange a code")
                return FakeResponse(status: 500)
            }, automaticallyRefreshesToken: false
        )
        await #expect(throws: CancellationError.self) {
            try await account.signIn { _ in throw CancellationError() }
        }
        #expect(try await account.cachedAccount() == nil)
    }

    @Test func keychainReadFailuresAreNotReportedAsSignedOut() async throws {
        struct LockedCredentials: AccountCredentialStorage {
            func store(key: String, value: Data) throws { throw AccountError.keychain(-25308) }
            func retrieve(key: String) throws -> Data? { throw AccountError.keychain(-25308) }
            func remove(key: String) throws { throw AccountError.keychain(-25308) }
            func keys(withPrefix prefix: String) throws -> [String] { throw AccountError.keychain(-25308) }
            func upgradeAccessibility() throws { throw AccountError.keychain(-25308) }
        }
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: LockedCredentials(),
            automaticallyRefreshesToken: false
        )
        await #expect(throws: AccountError.keychain(-25308)) { try await account.cachedAccount() }
    }

    @Test func preferenceChangesAreFreshSmallAndPreserveUnknownShapes() async throws {
        let metadata: [String: MetadataValue] = [
            "future": .object(["keep": .integer(7)]),
            "tags": .object([
                "a": .object(["name": .string("A"), "color": .string("gold"), "future": .bool(true)])
            ]),
            "gistTags": .object(["one": .array([.string("a")]), "other": .array([.string("a")])]),
            "pinnedGists": .array([.string("other")])
        ]
        let tag = try PreferenceOperation.upsertTag(id: "a", name: "Renamed", color: "blue").changes(in: metadata)
        #expect(tag.count == 1)
        #expect(tag["tags"]?.objectValue?["a"]?.objectValue?["future"] == .bool(true))
        let defaultColor = try PreferenceOperation.upsertTag(id: "a", name: "Default", color: nil).changes(in: metadata)
        #expect(defaultColor["tags"]?.objectValue?["a"]?.objectValue?["color"] == nil)
        #expect(defaultColor["tags"]?.objectValue?["a"]?.objectValue?["name"] == .string("Default"))
        #expect(defaultColor["tags"]?.objectValue?["a"]?.objectValue?["future"] == .bool(true))
        let pins = try PreferenceOperation.setPinned(gistID: "one", pinned: true).changes(in: metadata)
        #expect(pins == ["pinnedGists": .array([.string("other"), .string("one")])])
        let removal = try PreferenceOperation.setTag(gistID: "one", tagID: "a", included: false)
            .changes(in: metadata)
        #expect(removal["gistTags"]?.objectValue?["other"] == .array([.string("a")]))
        #expect(removal["future"] == nil)
        #expect(throws: PreferenceError.invalidShape("pinnedGists")) {
            try PreferenceOperation.setPinned(gistID: "one", pinned: true)
                .changes(in: ["pinnedGists": .string("legacy-value")])
        }
    }

    @Test func preferenceOperationRefetchesWebChangesBeforeSendingOnlyChangedFields() async throws {
        let requests = Mutex<[String]>([])
        let session = FakeURLProtocol.session { request in
            requests.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.lastPathComponent ?? "")") }
            if request.url?.path.hasSuffix("/token") == true {
                return FakeResponse(data: try authSession())
            }
            let fresh: [String: Any] = [
                "user_name": "test-user", "pinnedGists": ["web-pin"],
                "tags": ["a": ["name": "A", "color": "gold", "future": true]],
                "gistTags": ["web-gist": ["a"]],
                "future": ["web-edit": 7]
            ]
            if request.httpMethod == "PUT" {
                let body = try requestBody(request)
                let data = try #require(body["data"] as? [String: Any])
                #expect(Set(data.keys) == ["pinnedGists"])
                #expect(data["pinnedGists"] as? [String] == ["web-pin", "native-pin"])
                var updated = fresh
                updated["pinnedGists"] = ["web-pin", "native-pin"]
                return FakeResponse(data: try JSONSerialization.data(withJSONObject: authUser(metadata: updated)))
            }
            return FakeResponse(data: try JSONSerialization.data(withJSONObject: authUser(metadata: fresh)))
        }
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: MemoryCredentials(),
            session: session, automaticallyRefreshesToken: false
        )
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake-code")! }
        let updated = try await account.apply(
            .setPinned(gistID: "native-pin", pinned: true), accountID: testAccountID
        )
        #expect(updated.preferences.pinnedGists == ["web-pin", "native-pin"])
        #expect(updated.preferences.metadata["future"]?.objectValue?["web-edit"] == .integer(7))
        #expect(requests.withLock { $0 } == ["POST token", "GET user", "PUT user"])
    }

    @Test func gitHubAccessSurvivesSupabaseSessionRevocation() async throws {
        let credentials = MemoryCredentials()
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in FakeResponse(data: try authSession()) },
            automaticallyRefreshesToken: false
        )
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        // The SDK drops its session when Supabase revokes it.
        try credentials.remove(key: "gistpad-supabase-session")
        #expect(try await account.cachedAccount() == nil)
        #expect(try await account.connectedAccountID() == testAccountID)
        #expect(try await account.githubToken(accountID: testAccountID) == "fake-github")
        let reopened = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            automaticallyRefreshesToken: false
        )
        #expect(try await reopened.githubToken(accountID: testAccountID) == "fake-github")
        await #expect(throws: AccountError.accountChanged) {
            try await account.githubToken(accountID: UUID())
        }
    }

    @Test func existingInstallsRecordTheGitHubConnectionWhenTheSessionIsRestored() async throws {
        let credentials = MemoryCredentials()
        let signedIn = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in FakeResponse(data: try authSession()) },
            automaticallyRefreshesToken: false
        )
        _ = try await signedIn.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        // Builds before the connection record stored only the token and the Supabase session.
        var session = try JSONDecoder().decode(
            Session.self, from: try #require(try credentials.retrieve(key: "gistpad-supabase-session"))
        )
        session.providerToken = nil
        try credentials.store(key: "gistpad-supabase-session", value: JSONEncoder().encode(session))
        try credentials.remove(key: "github-connection")
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in
                Issue.record("Restoring a stored session must not use the network")
                return FakeResponse(status: 500)
            }, automaticallyRefreshesToken: false
        )
        #expect(try await account.cachedAccount()?.id == testAccountID)
        #expect(try credentials.retrieve(key: "github-connection") == Data(testAccountID.uuidString.utf8))
        try credentials.remove(key: "gistpad-supabase-session")
        #expect(try await account.githubToken(accountID: testAccountID) == "fake-github")
    }

    @Test func missingGitHubTokenAsksForReconnectWhileSupabaseIsSignedIn() async throws {
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: MemoryCredentials(),
            session: FakeURLProtocol.session { _ in FakeResponse(data: try authSession(includeProvider: false)) },
            automaticallyRefreshesToken: false
        )
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        await #expect(throws: AccountError.reconnectGitHub) {
            try await account.githubToken(accountID: testAccountID)
        }
    }

    @Test func signOutAfterSessionRevocationStillDisconnectsGitHubWithoutNetwork() async throws {
        let credentials = MemoryCredentials()
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { request in
                if request.url?.path.hasSuffix("/logout") == true {
                    Issue.record("Sign-out with no Supabase session must not call Supabase")
                    return FakeResponse(status: 500)
                }
                return FakeResponse(data: try authSession())
            },
            automaticallyRefreshesToken: false
        )
        _ = try await account.signIn { _ in URL(string: "gistpad://auth-callback?code=fake")! }
        try credentials.remove(key: "gistpad-supabase-session")
        try await account.signOut(accountID: testAccountID)
        #expect(try await account.connectedAccountID() == nil)
        #expect(try credentials.retrieve(key: "github-provider-\(testAccountID.uuidString)") == nil)
        await #expect(throws: AccountError.signedOut) {
            try await account.githubToken(accountID: testAccountID)
        }
    }

    @Test func legacyInstallWithOnlyATokenAdoptsItsGitHubConnection() async throws {
        let credentials = MemoryCredentials()
        try credentials.store(
            key: "github-provider-\(testAccountID.uuidString)", value: Data("fake-github".utf8)
        )
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            automaticallyRefreshesToken: false
        )
        #expect(try await account.githubToken(accountID: testAccountID) == "fake-github")
        #expect(try credentials.retrieve(key: "github-connection") == Data(testAccountID.uuidString.utf8))
    }

    @Test func ambiguousLegacyTokensAreNotAdopted() async throws {
        let credentials = MemoryCredentials()
        try credentials.store(key: "github-provider-\(testAccountID.uuidString)", value: Data("a".utf8))
        try credentials.store(key: "github-provider-\(UUID().uuidString)", value: Data("b".utf8))
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            automaticallyRefreshesToken: false
        )
        #expect(try await account.connectedAccountID() == nil)
        #expect(try credentials.retrieve(key: "github-connection") == nil)
    }

    @Test func keychainItemsUpgradeToAfterFirstUnlockWithoutLosingValues() throws {
        let service = "dev.gistpad.GistPad.tests.\(UUID().uuidString)"
        let store = CredentialStore(service: service)
        let scope: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        defer { SecItemDelete(scope as CFDictionary) }
        let item = scope.merging([
            kSecAttrAccount as String: "legacy",
            kSecValueData as String: Data("token".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, new in new }
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)

        try store.upgradeAccessibility()

        #expect(try store.retrieve(key: "legacy") == Data("token".utf8))
        #expect(try store.keys(withPrefix: "") == ["legacy"])
        var result: CFTypeRef?
        let lookup = scope.merging([
            kSecAttrAccount as String: "legacy",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        #expect(SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess)
        // macOS's legacy file keychain does not report the accessibility class, so the class is
        // asserted only where the data protection keychain (iOS) reports it.
        #if os(iOS)
        let attributes = result as? [String: Any]
        #expect(
            attributes?[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #endif
    }

    @Test func connectedAccountLaunchesFromTheSnapshotWithoutSupabaseOrNetwork() async throws {
        let credentials = MemoryCredentials()
        _ = try await signedInAccount(credentials: credentials)
        try credentials.remove(key: "gistpad-supabase-session")
        let requests = Mutex(0)
        let relaunched = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in
                requests.withLock { $0 += 1 }
                return FakeResponse(status: 500)
            },
            automaticallyRefreshesToken: false
        )
        let account = try #require(try await relaunched.connectedAccount())
        #expect(account.id == testAccountID)
        #expect(account.login == "test-user")
        #expect(requests.withLock { $0 } == 0)
    }

    @Test func upgradedInstallLearnsTheAccountOnceFromGitHubThenReusesTheSnapshot() async throws {
        let credentials = MemoryCredentials()
        try credentials.store(key: "github-connection", value: Data(testAccountID.uuidString.utf8))
        try credentials.store(key: "github-provider-\(testAccountID.uuidString)", value: Data("fake-github".utf8))
        let requests = Mutex<[(url: URL?, authorization: String?)]>([])
        let github = FakeURLProtocol.session { request in
            requests.withLock { $0.append((request.url, request.value(forHTTPHeaderField: "Authorization"))) }
            return FakeResponse(data: Data(
                #"{"id":42,"login":"test-user","avatar_url":"https://avatars.example/test.png"}"#.utf8
            ))
        }
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials, session: github,
            automaticallyRefreshesToken: false
        )
        let learned = try await account.connectedAccount()
        #expect(learned?.id == testAccountID)
        #expect(learned?.login == "test-user")
        #expect(learned?.githubUserID == 42)
        #expect(learned?.avatarURL == URL(string: "https://avatars.example/test.png"))
        let sent = requests.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent.first?.url == URL(string: "https://api.github.com/user"))
        #expect(sent.first?.authorization?.contains("fake-github") == true)

        let relaunched = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials, session: github,
            automaticallyRefreshesToken: false
        )
        #expect(try await relaunched.connectedAccount() == learned)
        #expect(requests.withLock { $0.count } == 1)
    }

    @Test func signOutAfterSessionLossClearsTheAccountSnapshot() async throws {
        let credentials = MemoryCredentials()
        _ = try await signedInAccount(credentials: credentials)
        try credentials.remove(key: "gistpad-supabase-session")
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in FakeResponse(status: 500) },
            automaticallyRefreshesToken: false
        )
        try await account.signOut(accountID: testAccountID)
        #expect(try credentials.retrieve(key: "github-account") == nil)
        #expect(try await account.connectedAccount() == nil)
    }

    @Test func failedGitHubDisconnectKeepsTheConnectionAndSnapshot() async throws {
        let credentials = ProviderRemovalFailureCredentials()
        _ = try await signedInAccount(credentials: credentials)
        try credentials.memory.remove(key: "gistpad-supabase-session")
        credentials.failsProviderRemoval.withLock { $0 = true }
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in FakeResponse(status: 500) },
            automaticallyRefreshesToken: false
        )
        await #expect(throws: AccountError.keychain(-25308)) {
            try await account.signOut(accountID: testAccountID)
        }
        #expect(try await account.connectedAccountID() == testAccountID)
        #expect(try await account.connectedAccount()?.login == "test-user")
    }

    @Test func failedPreferenceWriteThrowsAndKeepsTheStoredSnapshot() async throws {
        let credentials = MemoryCredentials()
        let failure = FakeResponse(status: 500, data: Data(#"{"message":"unavailable"}"#.utf8))
        let account = try await signedInAccount(credentials: credentials, update: failure)
        let stored = try #require(try credentials.retrieve(key: "github-account"))
        await #expect(throws: (any Error).self) {
            try await account.apply(.setAccentColor("#ff0000"), accountID: testAccountID)
        }
        #expect(try credentials.retrieve(key: "github-account") == stored)
    }

    @Test func successfulPreferenceWriteIsReflectedInTheLaunchSnapshot() async throws {
        let credentials = MemoryCredentials()
        let updated = try JSONSerialization.data(withJSONObject: authUser(
            metadata: ["user_name": "test-user", "sub": "42", "accentColor": "#ff0000"]
        ))
        let account = try await signedInAccount(credentials: credentials, update: FakeResponse(data: updated))
        let written = try await account.apply(.setAccentColor("#ff0000"), accountID: testAccountID)
        #expect(written.preferences.metadata["accentColor"]?.stringValue == "#ff0000")
        try credentials.remove(key: "gistpad-supabase-session")
        let relaunched = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in FakeResponse(status: 500) },
            automaticallyRefreshesToken: false
        )
        #expect(try await relaunched.connectedAccount() == written)
    }

    @Test func preferenceWriteWithoutASupabaseSessionFailsBeforeAnyNetworkCall() async throws {
        let credentials = MemoryCredentials()
        _ = try await signedInAccount(credentials: credentials)
        try credentials.remove(key: "gistpad-supabase-session")
        let requests = Mutex(0)
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: credentials,
            session: FakeURLProtocol.session { _ in
                requests.withLock { $0 += 1 }
                return FakeResponse(status: 500)
            },
            automaticallyRefreshesToken: false
        )
        await #expect(throws: AccountError.signedOut) {
            try await account.apply(.setAccentColor("#ff0000"), accountID: testAccountID)
        }
        #expect(requests.withLock { $0 } == 0)
    }
}
