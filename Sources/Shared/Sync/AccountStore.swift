import Auth
import Foundation
import OSLog
import Security

public enum AccountError: Error, Equatable, Sendable {
    case invalidConfiguration
    case busy
    case signedOut
    case accountChanged
    case reconnectGitHub
    case credentialPersistence
    case keychain(OSStatus)
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "GitHub sign-in isn't configured correctly in this build.")
        case .busy: String(localized: "Wait for your account to finish updating, then try again.")
        case .signedOut, .accountChanged, .reconnectGitHub:
            String(localized: "Reconnect GitHub to continue. Your gists on this iPhone are unchanged.")
        case .credentialPersistence:
            String(localized: "Your sign-in couldn't be saved on this iPhone. Sign in again.")
        case .keychain: String(localized: "GistPad couldn't use your sign-in on this iPhone. Sign in again.")
        }
    }
}

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let login: String
    public let githubUserID: Int64?
    public let avatarURL: URL?
    public let preferences: Preferences
    public var displayName: String? { preferences.profileDisplayName }

    public init(
        id: UUID, login: String, githubUserID: Int64? = nil, avatarURL: URL? = nil, preferences: Preferences
    ) {
        self.id = id
        self.login = login
        self.githubUserID = githubUserID
        self.avatarURL = avatarURL
        self.preferences = preferences
    }
}

/// Where the GitHub token and Supabase session live, on this device only.
public struct Keychain: AuthLocalStorage {
    private let service: String

    public init(service: String = "dev.gistpad.GistPad.credentials") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
    }

    public func store(key: String, value: Data) throws {
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

    public func retrieve(key: String) throws -> Data? {
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

    public func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.keychain(status)
        }
    }
}

public actor AccountStore {
    public static let projectURL = URL(string: "https://upnfachynwuwialgybvf.supabase.co")!
    public static let callbackURL = URL(string: "gistpad://auth-callback")!
    private static let sessionKey = "gistpad-supabase-session"
    private static let connectionKey = "github-connection"
    private static let accountKey = "github-account"
    private static let providerPrefix = "github-provider-"
    private static let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "account")
    private let auth: AuthClient
    private let credentials: any AuthLocalStorage
    private let authEvents: Task<Void, Never>
    private let publishableKey: String
    private let httpSession: URLSession
    private let launchFlow: LaunchFlow?
    private var signingIn = false
    private var signingOut = false
    private var updatingPreferences = false

    /// Stands in for the system web session: it gets the sign-in URL and returns the callback.
    typealias LaunchFlow = @MainActor @Sendable (URL) async throws -> URL

    public init(
        publishableKey: String,
        credentials: any AuthLocalStorage = Keychain(),
        session: URLSession? = nil,
        automaticallyRefreshesToken: Bool = true
    ) throws {
        try self.init(
            publishableKey: publishableKey, credentials: credentials, session: session,
            automaticallyRefreshesToken: automaticallyRefreshesToken, launchFlow: nil)
    }

    /// An account whose `signIn()` goes through `launchFlow`. The fixture server uses this.
    init(
        publishableKey: String, credentials: any AuthLocalStorage, session: URLSession?,
        automaticallyRefreshesToken: Bool, launchFlow: LaunchFlow?
    ) throws {
        guard Self.isPublishableKey(publishableKey) else {
            throw AccountError.invalidConfiguration
        }
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
        let client = auth
        authEvents = Task {
            for await (event, _) in client.authStateChanges {
                Self.logger.info("Supabase auth event: \(event.rawValue, privacy: .public)")
            }
        }
    }

    deinit { authEvents.cancel() }

    public func cachedAccount() async throws -> Account? {
        guard !signingOut else { throw AccountError.busy }
        guard let session = try persistedSession() else { return nil }
        return snapshot(session.user)
    }

    /// The connected GitHub account for launch. It doesn't need a live Supabase session.
    public func connectedAccount() async throws -> Account? {
        if try persistedSession() != nil { return try await cachedAccount() }
        guard let id = try connectedAccountID(), let stored = try storedAccount(), stored.id == id else {
            return nil
        }
        return stored
    }

    public func refreshAccount() async throws -> Account {
        guard !signingIn, !signingOut else { throw AccountError.busy }
        _ = try persistedSession()
        let user = try await auth.user()
        guard try persistedSession()?.user.id == user.id else { throw AccountError.accountChanged }
        let account = snapshot(user)
        persistAccount(account)
        return account
    }

    @discardableResult
    public func signIn() async throws -> Account {
        try await signIn(launchFlow: launchFlow)
    }

    /// Signs in through `launchFlow` instead of the system web session.
    @discardableResult
    func signIn(launchFlow: LaunchFlow?) async throws -> Account {
        guard !signingIn, !signingOut, !updatingPreferences else { throw AccountError.busy }
        signingIn = true
        defer { signingIn = false }
        let session = if let launchFlow {
            try await auth.signInWithOAuth(
                provider: .github, redirectTo: Self.callbackURL, scopes: "gist", launchFlow: launchFlow)
        } else {
            try await auth.signInWithOAuth(provider: .github, redirectTo: Self.callbackURL, scopes: "gist")
        }
        try verifyPersistedSession(session)
        // Only sign-in's session carries GitHub's token, because Supabase refreshes don't resend it.
        if let token = session.providerToken, !token.isEmpty {
            try credentials.store(key: providerKey(session.user.id), value: Data(token.utf8))
        }
        try credentials.store(key: Self.connectionKey, value: Data(session.user.id.uuidString.utf8))
        let account = snapshot(session.user)
        persistAccount(account)
        return account
    }

    static func isPublishableKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") { return key.count > "sb_publishable_".count }
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["role"] as? String == "anon"
    }

    public func githubClient(accountID: UUID) -> GitHubClient {
        GitHubClient(session: httpSession) { [self] in try await githubToken(accountID: accountID) }
    }

    public func imageStorage(accountID: UUID) throws -> ImageStorage {
        try ImageStorage(publishableKey: publishableKey, session: httpSession) { [self] in
            try await storageToken(accountID: accountID)
        }
    }

    private func storageToken(accountID: UUID) async throws -> String {
        guard !signingIn, !signingOut else { throw AccountError.accountChanged }
        guard let persisted = try persistedSession() else { throw AccountError.signedOut }
        guard persisted.user.id == accountID else { throw AccountError.accountChanged }
        let session = try await auth.session
        guard session.user.id == accountID, try persistedSession()?.user.id == accountID else {
            throw AccountError.accountChanged
        }
        return session.accessToken
    }

    func githubToken(accountID: UUID) async throws -> String {
        guard !signingIn, !signingOut else { throw AccountError.accountChanged }
        guard let connected = try connectedAccountID() else { throw AccountError.signedOut }
        guard connected == accountID else { throw AccountError.accountChanged }
        guard let data = try credentials.retrieve(key: providerKey(accountID)),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AccountError.reconnectGitHub
        }
        return token
    }

    /// Folds `changes` over the web's latest metadata and writes the changed keys once, so a batch lands whole or not at all.
    public func update(_ changes: [Preferences.Change], accountID: UUID) async throws -> Account {
        guard !updatingPreferences, !signingIn, !signingOut else { throw PreferenceError.operationInProgress }
        updatingPreferences = true
        defer { updatingPreferences = false }
        // Without a Supabase session there is nowhere to write, so fail before any network call.
        guard let session = try persistedSession() else { throw AccountError.signedOut }
        guard session.user.id == accountID else { throw AccountError.accountChanged }
        let user = try await auth.user()
        guard user.id == accountID, try persistedSession()?.user.id == accountID else {
            throw AccountError.accountChanged
        }
        var metadata = user.userMetadata
        var written: [String: MetadataValue] = [:]
        for change in changes {
            let values = try change.changes(in: metadata)
            metadata.merge(values) { _, new in new }
            written.merge(values) { _, new in new }
        }
        let updated = try await auth.update(user: UserAttributes(data: written))
        guard updated.id == accountID, try persistedSession()?.user.id == accountID else {
            throw AccountError.accountChanged
        }
        let account = snapshot(updated)
        persistAccount(account)
        return account
    }

    // The caller must first let the user keep/export/discard account-scoped unsynced work.
    public func signOut(accountID: UUID) async throws {
        guard !signingIn, !signingOut, !updatingPreferences else { throw AccountError.busy }
        guard try connectedAccountID() == accountID else { throw AccountError.accountChanged }
        signingOut = true
        defer { signingOut = false }
        try credentials.remove(key: providerKey(accountID))
        guard try persistedSession() != nil else {
            try removeLocalCredentials(accountID: accountID)
            return
        }
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
        try credentials.remove(key: Self.connectionKey)
        try credentials.remove(key: Self.accountKey)
        try credentials.remove(key: Self.sessionKey)
    }

    /// The GitHub account this device is connected to. It survives Supabase session loss, so GitHub reads don't depend on Supabase.
    public func connectedAccountID() throws -> UUID? {
        guard !signingOut else { throw AccountError.busy }
        if let session = try persistedSession() { return session.user.id }
        if let data = try credentials.retrieve(key: Self.connectionKey) {
            guard let id = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)) else {
                throw AccountError.credentialPersistence
            }
            return id
        }
        return nil
    }

    private func providerKey(_ id: UUID) -> String { Self.providerPrefix + id.uuidString }

    private func storedAccount() throws -> Account? {
        guard let data = try credentials.retrieve(key: Self.accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    // The snapshot is a launch cache. Supabase and GitHub stay authoritative, so a failed write is logged, not surfaced as a failed sign-in or save.
    private func persistAccount(_ account: Account) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            let data = try encoder.encode(account)
            guard try credentials.retrieve(key: Self.accountKey) != data else { return }
            try credentials.store(key: Self.accountKey, value: data)
        } catch {
            Self.logger.error("Couldn't save the account snapshot: \(String(describing: error), privacy: .public)")
        }
    }

    private func persistedSession() throws -> Session? {
        try credentials.retrieve(key: Self.sessionKey).map {
            try JSONDecoder().decode(Session.self, from: $0)
        }
    }

    private func verifyPersistedSession(_ session: Session) throws {
        // The SDK logs storage errors instead of throwing. Never claim a non-durable sign-in.
        guard let saved = try persistedSession(), saved.user.id == session.user.id,
              saved.refreshToken == session.refreshToken else { throw AccountError.credentialPersistence }
    }

    private func snapshot(_ user: User) -> Account {
        Account(
            id: user.id,
            login: user.userMetadata["user_name"]?.stringValue ?? "",
            githubUserID: githubUserID(user),
            avatarURL: user.userMetadata["avatar_url"]?.stringValue.flatMap(URL.init(string:)),
            preferences: Preferences(metadata: user.userMetadata)
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
