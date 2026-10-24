import Auth
import Foundation
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

@Suite struct AccountTests {
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

    @Test func rejectsWrongCallbackBeforeExchangingCode() async throws {
        let requests = Mutex(0)
        let session = FakeURLProtocol.session { _ in
            requests.withLock { $0 += 1 }
            return FakeResponse(status: 500)
        }
        let account = try AccountService(
            publishableKey: "sb_publishable_fake", credentials: MemoryCredentials(),
            session: session, automaticallyRefreshesToken: false
        )
        await #expect(throws: AccountError.invalidCallback) {
            try await account.signIn { _ in URL(string: "gistpad://not-auth?code=fake")! }
        }
        #expect(requests.withLock { $0 } == 0)
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
        struct LockedCredentials: AuthLocalStorage {
            func store(key: String, value: Data) throws { throw AccountError.keychain(-25308) }
            func retrieve(key: String) throws -> Data? { throw AccountError.keychain(-25308) }
            func remove(key: String) throws { throw AccountError.keychain(-25308) }
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
}
