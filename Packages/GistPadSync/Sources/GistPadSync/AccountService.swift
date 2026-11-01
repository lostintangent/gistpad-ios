import Auth
import Foundation
import OSLog
import Security

public enum AccountError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidCallback
    case signInInProgress
    case signedOut
    case accountChanged
    case reconnectGitHub
    case credentialPersistence
    case keychain(OSStatus)
}

public struct AccountSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let login: String
    public let githubUserID: Int64?
    public let avatarURL: URL?
    public let preferences: Preferences
}

public protocol AccountCredentialStorage: AuthLocalStorage {
    func keys(withPrefix prefix: String) throws -> [String]
    func upgradeAccessibility() throws
}

public struct CredentialStore: AccountCredentialStorage {
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

    public func keys(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }

    // Items saved by earlier builds kept the stricter ThisDeviceOnly class, which fails for locked background refreshes.
    public func upgradeAccessibility() throws {
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        for key in try keys(withPrefix: "") {
            let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccountError.keychain(status)
            }
        }
    }
}

public actor AccountService {
    public static let projectURL = URL(string: "https://upnfachynwuwialgybvf.supabase.co")!
    public static let callbackURL = URL(string: "gistpad://auth-callback")!
    private static let sessionKey = "gistpad-supabase-session"
    private static let connectionKey = "github-connection"
    private static let providerPrefix = "github-provider-"
    private static let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "account")
    private let auth: AuthClient
    private let credentials: any AccountCredentialStorage
    private let authEvents: Task<Void, Never>
    private let publishableKey: String
    private var signingIn = false
    private var signingOut = false
    private var updatingPreferences = false

    public init(
        publishableKey: String,
        credentials: any AccountCredentialStorage = CredentialStore(),
        session: URLSession? = nil,
        automaticallyRefreshesToken: Bool = true
    ) throws {
        guard Self.isPublishableKey(publishableKey) else {
            throw AccountError.invalidConfiguration
        }
        self.credentials = credentials
        self.publishableKey = publishableKey
        let session = session ?? GitHubClient.makeSession()
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
        do {
            try credentials.upgradeAccessibility()
        } catch {
            Self.logger.error("Couldn't update keychain accessibility: \(String(describing: error), privacy: .public)")
        }
        let client = auth
        authEvents = Task {
            for await (event, _) in client.authStateChanges {
                Self.logger.info("Supabase auth event: \(event.rawValue, privacy: .public)")
            }
        }
    }

    deinit { authEvents.cancel() }

    public func cachedAccount() async throws -> AccountSnapshot? {
        guard !signingOut else { throw AccountError.signInInProgress }
        guard let session = try persistedSession() else { return nil }
        try retainConnection(session)
        return snapshot(session.user)
    }

    public func refreshAccount() async throws -> AccountSnapshot {
        guard !signingIn, !signingOut else { throw AccountError.signInInProgress }
        _ = try persistedSession()
        let session = try await auth.session
        try retainConnection(session)
        let user = try await auth.user()
        guard try persistedSession()?.user.id == user.id else { throw AccountError.accountChanged }
        return snapshot(user)
    }

    @discardableResult
    public func signIn() async throws -> AccountSnapshot {
        guard !signingIn, !signingOut, !updatingPreferences else { throw AccountError.signInInProgress }
        signingIn = true
        defer { signingIn = false }
        let session = try await auth.signInWithOAuth(
            provider: .github, redirectTo: Self.callbackURL, scopes: "gist"
        )
        try verifyPersistedSession(session)
        try retainConnection(session)
        return snapshot(session.user)
    }

    @discardableResult
    public func signIn(
        launchFlow: @MainActor @Sendable (URL) async throws -> URL
    ) async throws -> AccountSnapshot {
        guard !signingIn, !signingOut, !updatingPreferences else { throw AccountError.signInInProgress }
        signingIn = true
        defer { signingIn = false }
        let session = try await auth.signInWithOAuth(
            provider: .github, redirectTo: Self.callbackURL, scopes: "gist"
        ) { url in
            let callback = try await launchFlow(url)
            try Self.validateCallback(callback)
            return callback
        }
        try verifyPersistedSession(session)
        try retainConnection(session)
        return snapshot(session.user)
    }

    private static func validateCallback(_ url: URL) throws {
        guard url.scheme == callbackURL.scheme, url.host == callbackURL.host,
              url.path.isEmpty, url.port == nil, url.user == nil, url.password == nil,
              url.fragment == nil else { throw AccountError.invalidCallback }
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

    public func githubClient(accountID: UUID, session: URLSession? = nil) -> GitHubClient {
        GitHubClient(session: session) { [self] in try await githubToken(accountID: accountID) }
    }

    public func imageStorageClient(accountID: UUID, session: URLSession? = nil) throws -> ImageStorageClient {
        try ImageStorageClient(publishableKey: publishableKey, session: session) { [self] in
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

    public func apply(_ operation: PreferenceOperation, accountID: UUID) async throws -> AccountSnapshot {
        guard !updatingPreferences, !signingIn, !signingOut else { throw PreferenceError.operationInProgress }
        updatingPreferences = true
        defer { updatingPreferences = false }
        let user = try await auth.user()
        guard user.id == accountID, try persistedSession()?.user.id == accountID else {
            throw AccountError.accountChanged
        }
        let changes = try operation.changes(in: user.userMetadata)
        let updated = try await auth.update(user: UserAttributes(data: changes))
        guard updated.id == accountID, try persistedSession()?.user.id == accountID else {
            throw AccountError.accountChanged
        }
        return snapshot(updated)
    }

    // The caller must first let the user keep/export/discard account-scoped unsynced work.
    public func signOut(accountID: UUID) async throws {
        guard !signingIn, !signingOut, !updatingPreferences else { throw AccountError.signInInProgress }
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

    // The connection survives a failed token removal, so the account stays visibly connected instead of being re-adopted.
    private func removeLocalCredentials(accountID: UUID) throws {
        let providerRemoval = Result { try credentials.remove(key: providerKey(accountID)) }
        let connectionRemoval = Result {
            guard case .success = providerRemoval else { return }
            try credentials.remove(key: Self.connectionKey)
        }
        let sessionRemoval = Result { try credentials.remove(key: Self.sessionKey) }
        try providerRemoval.get()
        try connectionRemoval.get()
        try sessionRemoval.get()
    }

    /// The GitHub account this device is connected to. It survives Supabase session loss, so GitHub reads don't depend on Supabase.
    public func connectedAccountID() throws -> UUID? {
        guard !signingOut else { throw AccountError.signInInProgress }
        if let session = try persistedSession() {
            try retainConnection(session)
            return session.user.id
        }
        if let data = try credentials.retrieve(key: Self.connectionKey) {
            guard let id = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)) else {
                throw AccountError.credentialPersistence
            }
            return id
        }
        return try adoptLegacyConnection()
    }

    // Builds before the connection record kept only the token. Adopt it only when it's unambiguous.
    private func adoptLegacyConnection() throws -> UUID? {
        let legacy = try credentials.keys(withPrefix: Self.providerPrefix)
        guard legacy.count == 1,
              let id = UUID(uuidString: String(legacy[0].dropFirst(Self.providerPrefix.count))) else {
            return nil
        }
        try credentials.store(key: Self.connectionKey, value: Data(id.uuidString.utf8))
        return id
    }

    private func retainConnection(_ session: Session) throws {
        guard !signingOut, try persistedSession()?.user.id == session.user.id else {
            throw AccountError.accountChanged
        }
        if let token = session.providerToken, !token.isEmpty {
            try credentials.store(key: providerKey(session.user.id), value: Data(token.utf8))
        }
        let connection = Data(session.user.id.uuidString.utf8)
        if try credentials.retrieve(key: Self.connectionKey) != connection {
            try credentials.store(key: Self.connectionKey, value: connection)
        }
    }

    private func providerKey(_ id: UUID) -> String { Self.providerPrefix + id.uuidString }

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

    private func snapshot(_ user: User) -> AccountSnapshot {
        AccountSnapshot(
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
