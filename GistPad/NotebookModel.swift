import AuthenticationServices
import Foundation
import GistPadInterface
import GistPadSync
import Observation
import OSLog

struct NotebookAccount: Equatable, Sendable, Identifiable {
    let id: UUID
    let login: String
    let githubUserID: Int64?
    let preferences: Preferences

    init(id: UUID, login: String, githubUserID: Int64? = nil, preferences: Preferences) {
        self.id = id
        self.login = login
        self.githubUserID = githubUserID
        self.preferences = preferences
    }

    init(_ snapshot: AccountSnapshot) {
        self.init(id: snapshot.id, login: snapshot.login, githubUserID: snapshot.githubUserID, preferences: snapshot.preferences)
    }
}

protocol NotebookProviding: Sendable {
    func cachedAccount() async throws -> NotebookAccount?
    func signIn() async throws -> NotebookAccount
    func refreshAccount() async throws -> NotebookAccount
    func gists(accountID: UUID) async throws -> [Gist]
    func starredGists(accountID: UUID) async throws -> [Gist]
    func gist(id: String, accountID: UUID) async throws -> Gist
    func content(gist: Gist, filename: String, accountID: UUID) async throws -> String
    func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot
    func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws -> DraftSnapshot
    func publish(draftID: UUID, accountID: UUID) async throws -> DraftSnapshot
}

actor LiveNotebookProvider: NotebookProviding {
    let accounts: AccountService
    let drafts: DraftStore
    private var clients: [UUID: GitHubClient] = [:]
    private var coordinators: [UUID: SyncCoordinator] = [:]

    init(accounts: AccountService, drafts: DraftStore) {
        self.accounts = accounts
        self.drafts = drafts
    }

    private func client(accountID: UUID) async -> GitHubClient {
        if let client = clients[accountID] { return client }
        let client = await accounts.githubClient(accountID: accountID)
        if let existing = clients[accountID] { return existing }
        clients[accountID] = client
        return client
    }

    func cachedAccount() async throws -> NotebookAccount? {
        try await accounts.cachedAccount().map(NotebookAccount.init)
    }

    func signIn() async throws -> NotebookAccount {
        NotebookAccount(try await accounts.signIn())
    }

    func refreshAccount() async throws -> NotebookAccount {
        NotebookAccount(try await accounts.refreshAccount())
    }

    func gists(accountID: UUID) async throws -> [Gist] {
        let client = await client(accountID: accountID)
        return try await client.listGists()
    }

    func starredGists(accountID: UUID) async throws -> [Gist] {
        let client = await client(accountID: accountID)
        return try await client.listStarredGists()
    }

    func gist(id: String, accountID: UUID) async throws -> Gist {
        let client = await client(accountID: accountID)
        return try await client.gist(id: id)
    }

    func content(gist: Gist, filename: String, accountID: UUID) async throws -> String {
        let client = await client(accountID: accountID)
        return try await client.content(gist: gist, filename: filename)
    }

    func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
        guard let account = try await accounts.cachedAccount(), account.id == document.accountID else {
            throw AccountError.accountChanged
        }
        let client = await client(accountID: document.accountID)
        let githubUserID: Int64
        if let id = account.githubUserID {
            githubUserID = id
        } else {
            githubUserID = try await client.authenticatedUser().id
        }
        let existing = try await drafts.drafts(accountID: document.accountID).first {
            $0.gistID == document.gist.id && $0.filename == document.filename
        }
        guard let existing else {
            return try await drafts.openDraft(
                accountID: document.accountID, githubUserID: githubUserID,
                gistID: document.gist.id, filename: document.filename,
                description: document.gist.description ?? "",
                content: document.text, revision: document.gist.revision
            )
        }
        guard existing.state == .savedToGitHub, existing.attemptedGeneration == nil else { return existing }
        let generation = existing.generation
        let remote = try await client.gist(id: document.gist.id)
        let content = try await client.content(gist: remote, filename: document.filename)
        return try await drafts.refreshCleanDraft(
            id: existing.id, accountID: document.accountID, expectedGeneration: generation,
            content: content, revision: remote.revision
        ).snapshot
    }

    func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws -> DraftSnapshot {
        try await drafts.persist(id: draftID, accountID: accountID, text: text, generation: generation)
    }

    func publish(draftID: UUID, accountID: UUID) async throws -> DraftSnapshot {
        let coordinator = await coordinator(accountID: accountID)
        return try await coordinator.publish(id: draftID, accountID: accountID)
    }

    private func coordinator(accountID: UUID) async -> SyncCoordinator {
        if let coordinator = coordinators[accountID] { return coordinator }
        let client = await client(accountID: accountID)
        if let existing = coordinators[accountID] { return existing }
        let coordinator = SyncCoordinator(client: client, store: drafts)
        coordinators[accountID] = coordinator
        return coordinator
    }
}

struct NotebookDocument: Equatable, Sendable, Identifiable {
    let accountID: UUID
    let gist: Gist
    let filename: String
    let text: String
    let chrome: NoteChrome

    var id: String { "\(accountID.uuidString)/\(gist.id)/\(filename)" }
}

@MainActor @Observable
final class NotebookModel {
    let library = LibraryModel()
    private(set) var account: NotebookAccount?
    private(set) var pendingAccount: NotebookAccount?
    private(set) var loadedDocument: NotebookDocument?
    private(set) var isSigningIn = false
    private(set) var isOpeningDocument = false
    var documentError: String?

    @ObservationIgnored private let provider: any NotebookProviding
    @ObservationIgnored private var libraryRequest = UUID()
    @ObservationIgnored private var documentRequest = UUID()
    @ObservationIgnored private var ownedGistIDs: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Notebook")

    init(provider: any NotebookProviding) {
        self.provider = provider
    }

    convenience init(publishableKey: String) throws {
        self.init(provider: LiveNotebookProvider(
            accounts: try AccountService(publishableKey: publishableKey),
            drafts: try DraftStore.open()
        ))
    }

    func start() async {
        let request = UUID()
        libraryRequest = request
        library.loadState = .loading
        do {
            let restored = try await provider.cachedAccount()
            guard request == libraryRequest else { return }
            guard let restored else {
                library.loadState = .signedOut
                return
            }
            account = restored
            await refresh()
        } catch is CancellationError {
            if request == libraryRequest {
                library.loadState = account == nil ? .signedOut : .ready
            }
        } catch {
            guard request == libraryRequest else { return }
            report(error, operation: "restore")
            library.loadState = .failed(message: Self.message(for: error))
        }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        let previousState = library.loadState
        defer { isSigningIn = false }
        do {
            let signedIn = try await provider.signIn()
            libraryRequest = UUID()
            if let account, account.id != signedIn.id {
                pendingAccount = signedIn
                library.loadState = .reconnectRequired(message: String(
                    localized: "A different GitHub account signed in. Keep or export the current account's drafts before switching."
                ))
                return
            }
            account = signedIn
            pendingAccount = nil
            await refresh()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            library.loadState = previousState
        } catch is CancellationError {
            library.loadState = previousState
        } catch {
            libraryRequest = UUID()
            report(error, operation: "sign-in")
            library.loadState = .reconnectRequired(message: Self.message(for: error))
        }
    }

    // The app calls this only after resolving the previous account's local work.
    func acceptPendingAccount() async {
        guard let pendingAccount else { return }
        libraryRequest = UUID()
        documentRequest = UUID()
        account = pendingAccount
        self.pendingAccount = nil
        loadedDocument = nil
        documentError = nil
        isOpeningDocument = false
        ownedGistIDs = []
        library.snapshot = .init(notes: [])
        library.selectedNoteID = nil
        library.clearFilters()
        await refresh()
    }

    func refresh() async {
        guard pendingAccount == nil else { return }
        guard let account else {
            await start()
            return
        }
        let request = UUID()
        libraryRequest = request
        let previousState = library.loadState
        library.loadState = .loading
        do {
            let refreshed = try await provider.refreshAccount()
            guard request == libraryRequest else { return }
            guard refreshed.id == account.id else { throw AccountError.accountChanged }
            async let owned = provider.gists(accountID: account.id)
            async let starred = provider.starredGists(accountID: account.id)
            let (ownedGists, starredGists) = try await (owned, starred)
            guard request == libraryRequest, self.account?.id == account.id else { return }
            self.account = refreshed
            ownedGistIDs = Set(ownedGists.map(\.id))
            library.snapshot = Self.librarySnapshot(owned: ownedGists, starred: starredGists, account: refreshed)
            library.loadState = .ready
        } catch is CancellationError {
            if request == libraryRequest { library.loadState = previousState }
        } catch {
            guard request == libraryRequest else { return }
            report(error, operation: "refresh")
            library.loadState = Self.isAuthorizationError(error)
                ? .reconnectRequired(message: Self.message(for: error))
                : .failed(message: Self.message(for: error))
        }
    }

    func open(gistID: String, filename: String? = nil) async {
        guard pendingAccount == nil, let account else {
            documentError = String(localized: "Reconnect GitHub before opening this note.")
            return
        }
        let request = UUID()
        documentRequest = request
        isOpeningDocument = true
        documentError = nil
        defer {
            if request == documentRequest { isOpeningDocument = false }
        }
        do {
            let gist = try await provider.gist(id: gistID, accountID: account.id)
            let filenames = gist.markdownFilenames
            let selectedFilename: String?
            if let filename {
                selectedFilename = filenames.contains(filename) ? filename : nil
            } else if gist.isDailyNote {
                let today = GistConventions.todayFilename()
                selectedFilename = filenames.contains(today) ? today : nil
            } else {
                selectedFilename = filenames.first
            }
            guard let selectedFilename else { throw GitHubClientError.missingFile }
            let text = try await provider.content(gist: gist, filename: selectedFilename, accountID: account.id)
            guard request == documentRequest, self.account?.id == account.id, pendingAccount == nil else { return }
            let owned = ownedGistIDs.contains(gist.id)
                || gist.owner?.login.caseInsensitiveCompare(account.login) == .orderedSame
            loadedDocument = NotebookDocument(
                accountID: account.id, gist: gist, filename: selectedFilename, text: text,
                chrome: NoteChrome(
                    title: gist.displayName,
                    files: filenames.map { NoteFile(id: $0, filename: $0) },
                    selectedFileID: selectedFilename, access: owned ? .editable : .readOnly,
                    isPinned: account.preferences.pinnedGists.contains(gist.id),
                    isStarred: library.snapshot.notes.first { $0.id == gist.id }?.isStarred ?? false,
                    isArchived: gist.isArchived
                )
            )
            library.selectedNoteID = gist.id
        } catch is CancellationError {
            if request == documentRequest { library.selectedNoteID = loadedDocument?.gist.id }
        } catch {
            guard request == documentRequest else { return }
            report(error, operation: "open")
            documentError = Self.message(for: error)
            library.selectedNoteID = loadedDocument?.gist.id
        }
    }

    func openDraft(for document: NotebookDocument) async throws -> DraftSnapshot {
        try await provider.openDraft(for: document)
    }

    func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws -> DraftSnapshot {
        try await provider.persist(draftID: draftID, accountID: accountID, text: text, generation: generation)
    }

    func publish(draftID: UUID, accountID: UUID) async throws -> DraftSnapshot {
        try await provider.publish(draftID: draftID, accountID: accountID)
    }

    static func librarySnapshot(owned: [Gist], starred: [Gist], account: NotebookAccount) -> LibrarySnapshot {
        let ownedIDs = Set(owned.map(\.id))
        let starredIDs = Set(starred.map(\.id))
        var unique: [String: Gist] = [:]
        for gist in owned + starred {
            if let existing = unique[gist.id], existing.updatedAt > gist.updatedAt { continue }
            unique[gist.id] = gist
        }
        let preferences = account.preferences
        return LibrarySnapshot(
            notes: unique.values.map { gist in
                LibraryNote(
                    id: gist.id, title: gist.displayName, updatedAt: gist.updatedAt,
                    owner: gist.owner?.login, isOwned: ownedIDs.contains(gist.id),
                    isSecret: !gist.isPublic, isPinned: preferences.pinnedGists.contains(gist.id),
                    isStarred: starredIDs.contains(gist.id), isArchived: gist.isArchived,
                    isDailyNote: gist.isDailyNote, tagIDs: Set(preferences.gistTags[gist.id] ?? [])
                )
            }.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            },
            tags: preferences.tags.map { id, value in
                LibraryTag(
                    id: id, name: value.objectValue?["name"]?.stringValue ?? id,
                    colorHex: value.objectValue?["color"]?.stringValue
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    static func interfaceSaveState(_ state: SaveState) -> NoteSaveState {
        switch state {
        case .savedLocally: .savedLocally
        case .savingToGitHub: .savingToGitHub
        case .savedToGitHub: .savedToGitHub
        case .offline:
            .cloudFailure(message: String(localized: "You're offline. Reconnect before saving to GitHub."))
        case .reconnect: .reconnectRequired
        case .conflict: .remoteChange
        case .failed(let failure):
            switch failure {
            case .creationUncertain: .creationUncertain
            case .publicationUncertain: .publicationUncertain
            case .readOnly:
                .publicationBlocked(message: String(localized: "This account no longer has permission to edit the gist."))
            case .incompleteRemote:
                .publicationBlocked(message: String(localized: "GitHub returned an incomplete note. Publishing could overwrite missing content."))
            case .network:
                .cloudFailure(message: String(localized: "GitHub couldn't confirm the save. Retry to check the remote version before publishing again."))
            case .http(let status, _):
                .cloudFailure(message: message(for: GitHubClientError.http(status: status, retryAfter: nil)))
            }
        }
    }

    private func report(_ error: any Error, operation: String) {
        logger.error("Notebook \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)")
    }

    private static func isAuthorizationError(_ error: any Error) -> Bool {
        if let error = error as? AccountError {
            return error == .signedOut || error == .accountChanged || error == .reconnectGitHub
        }
        if case GitHubClientError.http(let status, _) = error { return status == 401 }
        return false
    }

    static func message(for error: any Error) -> String {
        if isAuthorizationError(error) {
            return String(localized: "GitHub access needs to be reconnected. Your local work has not been removed.")
        }
        if let error = error as? GitHubClientError {
            switch error {
            case .incompleteGist:
                return String(localized: "GitHub returned an incomplete note. It cannot be edited safely.")
            case .missingFile:
                return String(localized: "The requested Markdown file is not available in this gist.")
            case .fileTooLarge:
                return String(localized: "This file is too large to open safely.")
            case .http(let status, _) where status == 403 || status == 429:
                return String(localized: "GitHub is limiting requests or denied access. Try again later or reconnect your account.")
            case .http(let status, _) where status == 404:
                return String(localized: "This gist is no longer available to this account.")
            default:
                return String(localized: "GitHub couldn't provide this note. Try again.")
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "You're offline. Reconnect to update your notebook. Existing local work is unchanged.")
            case .timedOut:
                return String(localized: "The request timed out. Try again when your connection is stable.")
            default:
                break
            }
        }
        if let error = error as? AccountError, error == .invalidConfiguration {
            return String(localized: "GitHub sign-in isn't configured correctly in this build.")
        }
        return String(localized: "Your notebook couldn't be updated. Try again. Existing local work is unchanged.")
    }
}
