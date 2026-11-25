import Auth
import Foundation
import Security

public enum AccountError: Error, Equatable, Sendable {
    case invalidConfiguration
    case signedOut
    case accountChanged
    case reconnectGitHub
    case keychain(OSStatus)
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "GitHub sign-in isn’t configured correctly in this build.")
        case .signedOut, .accountChanged, .reconnectGitHub:
            String(localized: "GitHub needs you to sign in again.")
        case .keychain: String(localized: "GistPad couldn’t use your sign-in on this iPhone.")
        }
    }
}

/// Who's signed in: your GitHub identity and your GistPad preferences.
public struct GistPadAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let github: GitHubUser
    public let preferences: GistPadPreferences
    /// Your name as GitHub gave it to Supabase.
    public var displayName: String? {
        ["full_name", "name"].lazy
            .compactMap { self.preferences.metadata[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    public init(id: UUID, github: GitHubUser, preferences: GistPadPreferences) {
        self.id = id
        self.github = github
        self.preferences = preferences
    }
}

/// Where the GitHub token and Supabase session live, on this device only.
private struct Keychain: AuthLocalStorage {
    private let service = "dev.gistpad.GistPad.credentials"

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
    }

    func store(key: String, value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let result = SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw AccountError.keychain(result) }
        } else if status != errSecSuccess {
            throw AccountError.keychain(status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
        guard let data = result as? Data else { throw AccountError.keychain(errSecDecode) }
        return data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.keychain(status)
        }
    }
}

public actor GistPadAccountStore {
    public static let projectURL = URL(string: "https://upnfachynwuwialgybvf.supabase.co")!
    public static let callbackURL = URL(string: "gistpad://auth-callback")!
    private static let sessionKey = "gistpad-supabase-session"
    private let auth: AuthClient
    private let credentials: any AuthLocalStorage
    private let publishableKey: String
    private let httpSession: URLSession
    private let launchFlow: (@MainActor @Sendable (URL) async throws -> URL)?

    /// An account store that signs in through `launchFlow`, which takes the sign-in URL and returns
    /// the callback, as the fixture server's does, or else through the system web session.
    public init(
        publishableKey: String, credentials: (any AuthLocalStorage)? = nil, session: URLSession? = nil,
        automaticallyRefreshesToken: Bool = true,
        launchFlow: (@MainActor @Sendable (URL) async throws -> URL)? = nil
    ) {
        let credentials = credentials ?? Keychain()
        self.launchFlow = launchFlow
        self.credentials = credentials
        self.publishableKey = publishableKey
        let session = session ?? GitHubClient.makeSession()
        httpSession = session
        auth = AuthClient(
            url: Self.projectURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": publishableKey, "Authorization": "Bearer \(publishableKey)"],
            flowType: .pkce,
            redirectToURL: Self.callbackURL,
            storageKey: Self.sessionKey,
            localStorage: credentials,
            logger: nil,
            fetch: { try await session.data(for: $0) },
            autoRefreshToken: automaticallyRefreshesToken,
            emitLocalSessionAsInitialSession: true
        )
    }

    /// The account Supabase's saved session belongs to, read without the network for launch. A
    /// sign-out on the web ends that session, and then there's none.
    public func connectedAccount() async throws -> GistPadAccount? {
        try persistedSession().map { try snapshot($0.user) }
    }

    public func refreshAccount() async throws -> GistPadAccount {
        try snapshot(await auth.user())
    }

    @discardableResult
    public func signIn() async throws -> GistPadAccount {
        let session = if let launchFlow {
            try await auth.signInWithOAuth(
                provider: .github, redirectTo: Self.callbackURL, scopes: "gist", launchFlow: launchFlow)
        } else {
            try await auth.signInWithOAuth(provider: .github, redirectTo: Self.callbackURL, scopes: "gist")
        }
        // Only sign-in's session carries GitHub's token, because Supabase refreshes don't resend it.
        if let token = session.providerToken, !token.isEmpty {
            try credentials.store(key: providerKey(session.user.id), value: Data(token.utf8))
        }
        return try snapshot(session.user)
    }

    public nonisolated func githubClient(accountID: UUID) -> GitHubClient {
        GitHubClient(session: httpSession) { [self] in try await githubToken(accountID: accountID) }
    }

    public nonisolated func imageStorage(accountID: UUID) -> ImageStorage {
        ImageStorage(publishableKey: publishableKey, session: httpSession) { [self] in
            try await storageToken(accountID: accountID)
        }
    }

    private func storageToken(accountID: UUID) async throws -> String {
        guard let persisted = try persistedSession() else { throw AccountError.signedOut }
        guard persisted.user.id == accountID else { throw AccountError.accountChanged }
        return try await auth.session.accessToken
    }

    func githubToken(accountID: UUID) async throws -> String {
        guard let session = try persistedSession() else { throw AccountError.signedOut }
        guard session.user.id == accountID else { throw AccountError.accountChanged }
        guard let data = try credentials.retrieve(key: providerKey(accountID)),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AccountError.reconnectGitHub
        }
        return token
    }

    /// Folds `changes` over the web's latest metadata and writes the changed keys once, so a batch lands whole or not at all.
    public func update(_ changes: [GistPadPreferences.Change], accountID: UUID) async throws -> GistPadAccount {
        // Without a Supabase session there is nowhere to write, so fail before any network call.
        guard let session = try persistedSession() else { throw AccountError.signedOut }
        guard session.user.id == accountID else { throw AccountError.accountChanged }
        let user = try await auth.user()
        guard user.id == accountID else { throw AccountError.accountChanged }
        var metadata = user.userMetadata
        var written: [String: AnyJSON] = [:]
        for change in changes {
            let values = try change.changes(in: metadata)
            metadata.merge(values) { _, new in new }
            written.merge(values) { _, new in new }
        }
        return try snapshot(await auth.update(user: UserAttributes(data: written)))
    }

    /// Ends the session and forgets the GitHub token on this iPhone. The account's drafts stay.
    public func signOut(accountID: UUID) async throws {
        guard let session = try persistedSession() else { return try removeLocalCredentials(accountID: accountID) }
        guard session.user.id == accountID else { throw AccountError.accountChanged }
        do {
            try await auth.signOut(scope: .local)
        } catch {
            try removeLocalCredentials(accountID: accountID)
            throw error
        }
        try removeLocalCredentials(accountID: accountID)
    }

    private func removeLocalCredentials(accountID: UUID) throws {
        try credentials.remove(key: providerKey(accountID))
        try credentials.remove(key: Self.sessionKey)
    }

    private func providerKey(_ id: UUID) -> String { "github-provider-\(id.uuidString)" }

    private func persistedSession() throws -> Session? {
        try credentials.retrieve(key: Self.sessionKey).map {
            try JSONDecoder().decode(Session.self, from: $0)
        }
    }

    private func snapshot(_ user: User) throws -> GistPadAccount {
        guard let githubID = githubUserID(user) else { throw AccountError.reconnectGitHub }
        return GistPadAccount(
            id: user.id,
            github: GitHubUser(
                id: githubID,
                login: user.userMetadata["user_name"]?.stringValue ?? "",
                avatarURL: user.userMetadata["avatar_url"]?.stringValue.flatMap(URL.init(string:))),
            preferences: GistPadPreferences(metadata: user.userMetadata)
        )
    }

    private func githubUserID(_ user: User) -> Int64? {
        let metadata = user.identities?.first { $0.provider == "github" }?.identityData ?? user.userMetadata
        for key in ["sub", "provider_id"] {
            if let value = metadata[key]?.stringValue, let id = Int64(value) { return id }
            if let value = metadata[key]?.intValue { return Int64(value) }
        }
        return nil
    }
}
