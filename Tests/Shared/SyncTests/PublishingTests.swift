import Foundation
import Synchronization
import Testing
@testable import Sync

/// Publishing when the connection drops after GitHub has already taken the request.
@Suite struct PublishingTests {
    @Test func typingAfterACutOffPublishPublishesWithoutAConflict() async throws {
        let fixture = try SyncFixture()
        let gist = fixture.server.addGist(description: "Note", files: ["README.md": "base"])
        cutOffNextPublish(fixture.server)
        let sent = try await fixture.type("local", in: fixture.open(gist))
        await #expect(throws: URLError.self) { try await fixture.publish(sent) }
        #expect(text(fixture.server, gist.id) == "local")

        let undone = try await fixture.type("base", in: fixture.store.draft(id: sent.id, accountID: SyncFixture.account))
        #expect(try await fixture.publish(undone).state == .savedToGitHub)
        #expect(text(fixture.server, gist.id) == "base")
    }

    @Test(arguments: [false, true])
    func aCutOffNewGistFindsWhatItMadeInsteadOfMakingAnother(daily: Bool) async throws {
        let fixture = try SyncFixture()
        try await fixture.store.cacheLibrary(
            owned: [], starred: [], preferences: .init(metadata: [:]), accountID: SyncFixture.account)
        // Same title and file with other text, so only the text tells them apart.
        fixture.server.addGist(description: "Ideas", files: ["README.md": "# Ideas\n\nOlder"])
        cutOffNextPublish(fixture.server)
        let draft = if daily {
            try await DailyNotes(
                accountID: SyncFixture.account, githubUserID: SyncFixture.user, client: fixture.github,
                store: fixture.store, publisher: fixture.publisher
            ).stageToday(target: DailyNote.Day(date: .now, timeZone: .gmt)).draft
        } else {
            try await fixture.store.newGistDraft(
                accountID: SyncFixture.account, githubUserID: SyncFixture.user, description: "Ideas",
                content: "# Ideas\n\nFirst")
        }
        await #expect(throws: URLError.self) { try await fixture.publish(draft) }

        let published = try await fixture.publish(draft)
        #expect(published.state == .savedToGitHub)
        let made = fixture.server.gists.filter { $0.files[draft.filename]?.content == draft.text }
        #expect(made.map(\.id) == [published.gistID])
        #expect(fixture.server.requests.filter { $0 == "POST /gists" }.count == 1)
    }
}

/// The next publish reaches GitHub, but its answer never comes back.
private func cutOffNextPublish(_ server: FixtureServer) {
    let session = server.session
    let isFirst = Mutex(true)
    server.intercept { request in
        guard request.httpMethod == "POST" || request.httpMethod == "PATCH",
              isFirst.withLock({ first in
                  defer { first = false }
                  return first
              })
        else { return nil }
        _ = try await session.data(for: request)
        throw URLError(.networkConnectionLost)
    }
}

private func text(_ server: FixtureServer, _ gistID: String, _ filename: String = "README.md") -> String? {
    server.gists.first { $0.id == gistID }?.files[filename]?.content
}
