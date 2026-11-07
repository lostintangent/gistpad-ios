import Auth
import Foundation
import Synchronization
import Testing
@testable import Store

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
            #expect(url.host == GistPadAccountStore.projectURL.host)
            #expect(query.first { $0.name == "provider" }?.value == "github")
            #expect(query.first { $0.name == "scopes" }?.value == "gist")
            #expect(query.first { $0.name == "redirect_to" }?.value == "gistpad://auth-callback")
            #expect(query.first { $0.name == "code_challenge_method" }?.value == "s256")
            #expect(query.first { $0.name == "code_challenge" }?.value?.isEmpty == false)
            return URL(string: "gistpad://auth-callback?code=fixture")!
        }
        #expect(account.id == id)
        #expect(account.github == FixtureServer.you)
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
        #expect(account.github == FixtureServer.you)
        #expect(attempts.withLock { $0 } == 0)
    }
}
