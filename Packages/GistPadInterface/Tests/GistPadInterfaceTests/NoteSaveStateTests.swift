import Testing
@testable import GistPadInterface

struct NoteSaveStateTests {
    @Test(arguments: [
        NoteSaveState.inMemoryFixture, .unsaved, .savedLocally, .offline, .savingToGitHub, .savedToGitHub
    ])
    func healthyAndOfflineStatesDoNotCreateAPersistentNotice(_ state: NoteSaveState) {
        #expect(state.issue == nil)
        #expect(!state.showsManualSave(isAutoSaveEnabled: true))
    }

    @Test(arguments: [
        NoteSaveState.cloudFailure(message: "Offline"),
        .localFailure(message: "Storage unavailable"), .remoteChange, .reconnectRequired,
        .creationUncertain, .publicationUncertain, .publicationBlocked(message: "Missing access")
    ])
    func actionableProblemsKeepTheirNotice(_ state: NoteSaveState) throws {
        let issue = try #require(state.issue)
        #expect(!issue.title.isEmpty)
        #expect(!issue.symbol.isEmpty)
    }

    @Test func failedPublishingRestoresManualSaveEvenWhenAutosaveIsEnabled() {
        #expect(NoteSaveState.cloudFailure(message: "Try again").showsManualSave(isAutoSaveEnabled: true))
        #expect(!NoteSaveState.localFailure(message: "Keep open").showsManualSave(isAutoSaveEnabled: true))
    }

    @Test func effectivePausedAutosaveKeepsTheDeliberateSaveReachable() {
        let state = NoteSaveState.savedLocally
        #expect(state.showsManualSave(isAutoSaveEnabled: false))
        #expect(!state.showsManualSave(isAutoSaveEnabled: true))
        #expect(NoteSaveState.offline.canPublish)
        #expect(!NoteSaveState.publicationUncertain.canPublish)
    }
}
