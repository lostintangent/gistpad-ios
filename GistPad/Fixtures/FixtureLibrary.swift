#if DEBUG
  import Foundation
  import GistPadPreview
  import GistPadSync

  /// One deterministic account, served by Sync's fixture GitHub, covering every row and screen Designer reviews.
  enum FixtureLibrary {
    static func seed(_ server: FixtureServer, now: Date = .now) throws {
      let hour: TimeInterval = 3_600
      let day: TimeInterval = 86_400

      // `addGist` puts each gist first, so add the oldest first.
      server.addGist(
        id: "finished", description: "A finished chapter [Archived]",
        files: ["chapter.md": "# A finished chapter\n\nEverything here is done, and kept for the record.\n"],
        updatedAt: now - 9 * day)
      server.addGist(
        id: "mixed", description: "日本語のメモ · أفكار صغيرة",
        files: ["memo.md": "# 日本語のメモ\n\n静かな朝に書く。\n\nأفكار صغيرة تكبر مع الوقت.\n"],
        updatedAt: now - 4 * day)
      server.addGist(
        id: "longtitle",
        description: "A long title that keeps going, to show how a row wraps when a gist has a lot to say",
        files: ["notes.md": "# A long title\n\nShort body.\n"],
        updatedAt: now - 2 * day)
      server.addGist(
        id: "words", description: "Words worth keeping",
        files: ["words.md": try PreviewFixtures.listMarkers], updatedAt: now - day)
      server.addGist(
        id: "highlights", description: "A notebook with comments",
        files: ["comments.md": highlightMarkdown], updatedAt: now - 5 * hour,
        comments: [
          "> quiet native\n\nThis is the tone to keep.",
          "> careful\n\nMaybe a softer word here?",
          "> A late native passage\n\nWorth the scroll.",
        ])
      server.addGist(
        id: "guide", description: "An excellent Markdown field guide",
        files: ["guide.md": try PreviewFixtures.allSyntax], updatedAt: now - 3 * hour,
        owner: FixtureServer.someoneElse, isStarred: true, comments: ["Bookmarking this for later."])
      server.addGist(
        id: "weekend", description: "A slower weekend",
        files: ["weekend.md": "# A slower weekend\n\n- [x] Farmers market\n- [ ] Long walk\n- [ ] Call home\n"],
        updatedAt: now - hour)
      server.addGist(
        id: "daily", description: GistConventions.dailyNotesDescription,
        files: [
          dailyFile(now - 3 * day): "# Notes\n\nNo tasks today.\n",
          dailyFile(now - 2 * day): "- [ ] Renew the passport\n- [ ] Book the dentist\n",
          dailyFile(now - day): "- [x] Water the plants\n- [x] Finish the outline\n",
          dailyFile(now): "- [x] Morning pages\n- [ ] Review the chapter\n- [ ] Call Mom\n",
        ],
        updatedAt: now - 30 * 60)
      server.addGist(
        id: "shape", description: "The shape of a notebook",
        files: [
          "README.md": try PreviewFixtures.readingPolish,
          "Ideas.md": "# Ideas\n\n- A margin for second thoughts\n- Pages that remember where you were\n",
        ],
        updatedAt: now - 10 * 60, comments: ["Love where this is going."])

      server.mergeMetadata([
        "pinnedGists": ["shape", "words"],
        "tags": [
          "ideas": ["name": "Ideas", "color": "#EBC85A"],
          "design": ["name": "Design", "color": "#548C80"],
          "personal": ["name": "Personal", "color": "#A88EB5"],
          "reading": ["name": "Reading list for the long winter evenings", "color": "#FFFFFF"],
          "ink": ["name": "Ink", "color": "#000000"],
          "someday": ["name": "Someday"],
        ],
        "gistTags": [
          "shape": ["ideas", "design"],
          "weekend": ["personal", "someday"],
          "words": ["ideas", "reading"],
          "mixed": ["personal", "ink"],
          "longtitle": ["reading", "ink", "someday", "design"],
        ],
      ])
    }

    private static func dailyFile(_ date: Date) -> String { GistConventions.todayFilename(date: date) }

    private static let highlightMarkdown =
      """
      # Comment notebook

      🫧 A quiet native note, with **careful** words.

      A café moment to keep. A notebook has room for a surprise.

      `native code` stays code in Preview.


      """
      + Array(repeating: "A little room for thoughts, sketches, and the shape of a good day.", count: 20)
      .joined(separator: "\n\n")
      + "\n\n## Further down\n\nA late native passage should scroll into view.\n"
  }
#endif
