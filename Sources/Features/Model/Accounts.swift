import AuthenticationServices
import Comments
import Editor
import Foundation
import Store

// One GitHub account at a time. Signing in as someone else signs you out first, and your drafts
// wait on this iPhone until you sign back in.

extension GistPadModel {
    public enum Phase: Sendable {
        case signedOut
        case signingIn
        /// Restoring the account and this iPhone's drafts at launch.
        case loading
        case ready
        /// Reading your gists from GitHub.
        case refreshing
        case signingOut

        /// Signing in or out, while the account may change under you.
        public var isChangingAccount: Bool { self == .signingIn || self == .signingOut }
    }

    public func start() async {
        guard phase != .signingOut else { return }
        let request = UUID()
        libraryRequest = request
        phase = .loading
        do {
            let restored = try await accountStore.connectedAccount()
            guard request == libraryRequest else { return }
            guard let restored else {
                phase = .signedOut
                return
            }
            account = restored
            try await reloadLocalState(accountID: restored.id)
            await refresh()
            await restoreLastOpened()
        } catch {
            guard request == libraryRequest else { return }
            phase = account == nil ? .signedOut : .ready
            guard !(error is CancellationError) else { return }
            report(error, operation: "restore")
            failure = Failure(error)
        }
    }

    public func signIn() async {
        guard !phase.isChangingAccount else { return }
        phase = .signingIn
        do {
            let signedIn = try await accountStore.signIn()
            libraryRequest = UUID()
            if account?.id == signedIn.id {
                account = signedIn
                phase = .ready
            } else {
                for fileEditor in editors.values {
                    fileEditor.editor.commitComposition()
                    await fileEditor.waitForPublication()
                    _ = await fileEditor.waitForLocalSave()
                }
                reset(to: signedIn)
            }
            try await reloadLocalState(accountID: signedIn.id)
            await refresh()
            await restoreLastOpened()
        } catch {
            if phase == .signingIn { phase = account == nil ? .signedOut : .ready }
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                || error is CancellationError
            {
                return
            }
            libraryRequest = UUID()
            report(error, operation: "sign-in")
            failure = Failure(error)
        }
    }

    /// Signs in again after GitHub refused the session, then publishes the open file if it's this
    /// account's, so the edits that waited go out.
    public func reconnect() async {
        await signIn()
        guard let activeEditor, account?.id == activeEditor.file.accountID, phase == .ready,
            refreshFailure == nil
        else { return }
        await activeEditor.publish()
    }

    /// The signed-in account, with this iPhone's drafts and cache loaded but nothing read from
    /// GitHub. App Intents use it, since they can run before the app's window starts the model.
    public func localAccount() async throws -> GistPadAccount? {
        guard !phase.isChangingAccount else {
            throw AccountError.accountChanged
        }
        if let account { return account }
        guard let restored = try await accountStore.connectedAccount() else { return nil }
        if let account { return account }
        account = restored
        try await reloadLocalState(accountID: restored.id)
        return restored
    }

    /// Uploads an image to GistPad's public storage, filed under the file's gist.
    public func uploadImage(_ image: Data, for file: GistFile) async throws -> URL {
        guard account?.id == file.accountID else {
            throw AccountError.accountChanged
        }
        guard let gistID = file.gistID else { throw DraftError.notFound }
        let storage = accountStore.imageStorage(accountID: file.accountID)
        return try await storage.upload(image, gistID: gistID)
    }

    /// Drops everything shown for the current account and switches to `account`, or signs out.
    func reset(to account: GistPadAccount?) {
        libraryRequest = UUID()
        fileRequest = UUID()
        self.account = account
        phase = account == nil ? .signedOut : .ready
        presented = nil
        opening = nil
        editors = [:]
        drafts = []
        gistCache = nil
        failure = nil
        refreshFailure = nil
        state.replace(gists: [], known: false)
        state.selectedID = nil
        state.clearFilters()
    }
}
