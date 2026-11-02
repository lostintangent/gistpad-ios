import Auth
import Foundation
import Synchronization
import Testing
@testable import GistPadSync

/// Sign in, sign out and reconnect, against the fixture Supabase.
@Suite struct AccountTests {
    private let id = FixtureServer.accountID
    private let sessionKey = "gistpad-supabase-session"

    @Test func signInRequestsGistScopeAndSurvivesRelaunch() async throws {
        let server = FixtureServer()
        let accounts = try server.accounts()
        await #expect(throws: (any Error).self) {
            try await accounts.signIn { _ in throw CancellationError() }
        }
        #expect(try await accounts.connectedAccount() == nil)

        let account = try await accounts.signIn { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(url.host == AccountService.projectURL.host)
            #expect(query.first { $0.name == "provider" }?.value == "github")
            #expect(query.first { $0.name == "scopes" }?.value == "gist")
            #expect(query.first { $0.name == "redirect_to" }?.value == "gistpad://auth-callback")
            #expect(query.first { $0.name == "code_challenge_method" }?.value == "s256")
            #expect(query.first { $0.name == "code_challenge" }?.value?.isEmpty == false)
            return URL(string: "gistpad://auth-callback?code=fixture")!
        }
        #expect(account.id == id)
        #expect(account.login == FixtureServer.you.login)
        #expect(account.githubUserID == FixtureServer.you.id)
        #expect(try await accounts.githubToken(accountID: id) == "fixture-github")

        // Supabase refreshes don't resend GitHub's token, so a relaunch keeps the one from sign-in.
        var stored = try JSONDecoder().decode(
            Session.self, from: #require(try server.credentials.retrieve(key: sessionKey)))
        stored.providerToken = nil
        try server.credentials.store(key: sessionKey, value: JSONEncoder().encode(stored))
        let relaunched = try server.accounts()
        #expect(try await relaunched.cachedAccount()?.id == id)
        #expect(try await relaunched.githubToken(accountID: id) == "fixture-github")
        #expect(server.requests.filter { $0 == "POST /auth/v1/token" }.count == 1)
    }

    @Test(arguments: [false, true])
    func signOutClearsTheAccountEvenWithoutNetwork(sessionRevoked: Bool) async throws {
        let server = FixtureServer()
        let accounts = try server.accounts()
        try await server.signIn(accounts)
        if sessionRevoked { try server.credentials.remove(key: sessionKey) }
        let attempts = Mutex<[String]>([])
        server.intercept { request in
            attempts.withLock { $0.append(request.url?.path ?? "") }
            throw URLError(.notConnectedToInternet)
        }

        try? await accounts.signOut(accountID: id)
        #expect(try await accounts.connectedAccountID() == nil)
        #expect(try await accounts.connectedAccount() == nil)
        #expect(try server.credentials.retrieve(key: "github-provider-\(id.uuidString)") == nil)
        #expect(try server.credentials.retrieve(key: "github-account") == nil)
        await #expect(throws: AccountError.signedOut) { try await accounts.githubToken(accountID: id) }
        #expect(try await server.accounts().connectedAccount() == nil)
        #expect(attempts.withLock { $0 }.allSatisfy { $0 == "/auth/v1/logout" })
        if sessionRevoked { #expect(attempts.withLock { $0 }.isEmpty) }
    }

    @Test func onlyAFailingGitHubTokenAsksToReconnect() async throws {
        let server = FixtureServer()
        let accounts = try server.accounts()
        try await server.signIn(accounts)
        // The SDK drops its session when Supabase revokes it, and GitHub keeps working.
        try server.credentials.remove(key: sessionKey)
        #expect(try await accounts.cachedAccount() == nil)
        #expect(try await accounts.connectedAccountID() == id)
        #expect(try await accounts.githubToken(accountID: id) == "fixture-github")
        #expect(try await server.accounts().githubToken(accountID: id) == "fixture-github")
        await #expect(throws: AccountError.accountChanged) { try await accounts.githubToken(accountID: UUID()) }

        try server.credentials.remove(key: "github-provider-\(id.uuidString)")
        await #expect(throws: AccountError.reconnectGitHub) { try await accounts.githubToken(accountID: id) }
    }

    @Test func connectedAccountLaunchesFromTheSnapshotWithoutSupabaseOrNetwork() async throws {
        let server = FixtureServer()
        try await server.signIn(server.accounts())
        try server.credentials.remove(key: sessionKey)
        let attempts = Mutex(0)
        server.intercept { _ in
            attempts.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let account = try #require(try await server.accounts().connectedAccount())
        #expect(account.id == id)
        #expect(account.login == FixtureServer.you.login)
        #expect(attempts.withLock { $0 } == 0)
    }

    @Test func preferenceWritesKeepWebChangesAndPersist() async throws {
        let server = FixtureServer()
        let accounts = try server.accounts()
        try await server.signIn(accounts)
        server.mergeMetadata([
            "pinnedGists": ["web-pin"], "future": ["web-edit": 7],
            "tags": ["a": ["name": "A", "color": "gold", "future": true]],
        ])
        let sent = Mutex<[String]>([])
        server.intercept { request in
            if request.httpMethod == "PUT" {
                let body = try JSONDecoder().decode([String: AnyJSON].self, from: FixtureServer.body(of: request))
                sent.withLock { $0 = body["data"]?.objectValue?.keys.sorted() ?? [] }
            }
            return nil
        }
        let before = server.requests.count

        let updated = try await accounts.apply(
            [.setPinned(gistID: "native-pin", pinned: true), .setTag(gistID: "native-pin", tagID: "a", included: true)],
            accountID: id)
        #expect(updated.preferences.pinnedGists == ["web-pin", "native-pin"])
        #expect(updated.preferences.tagNames(gistID: "native-pin") == ["A"])
        #expect(updated.preferences.metadata["future"]?.objectValue?["web-edit"] == .integer(7))
        #expect(sent.withLock { $0 } == ["gistTags", "pinnedGists"])
        #expect(Array(server.requests.dropFirst(before)) == ["GET /auth/v1/user", "PUT /auth/v1/user"])

        server.intercept { request in request.httpMethod == "PUT" ? .init(status: 500) : nil }
        await #expect(throws: (any Error).self) {
            try await accounts.apply([.setAccentColor("#ff0000")], accountID: id)
        }
        try server.credentials.remove(key: sessionKey)
        let relaunched = try #require(try await server.accounts().connectedAccount())
        #expect(relaunched == updated)
        #expect(relaunched.preferences.accentColor == nil)
    }
}
