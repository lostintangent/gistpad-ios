#if DEBUG
  import Foundation
  import Notebook
  import Preview
  import Sync

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
        files: [
          "notes.md": "# A long title\n\nShort body.\n",
          "outline.md": "# Outline\n\n1. Start small\n2. Keep going\n",
          "sources.md": "# Sources\n\n- The library\n",
        ],
        updatedAt: now - 2 * day)
      server.addGist(
        id: "words", description: "Words worth keeping",
        files: ["words.md": try PreviewFixtures.listMarkers], updatedAt: now - day)
      server.addGist(
        id: "highlights", description: "A gist with comments",
        files: ["comments.md": highlightMarkdown], updatedAt: now - 5 * hour,
        comments: [
          "> quiet native\n\nThis is the tone to keep.",
          "> careful\n\nMaybe a softer word here?",
          "> A late native passage\n\nWorth the scroll.",
        ])
      server.addGist(
        id: "guide", description: "An excellent Markdown field guide",
        files: ["guide.md": try PreviewFixtures.allSyntax, "tips.md": "# Tips\n\nKeep headings short.\n"],
        updatedAt: now - 3 * hour,
        owner: FixtureServer.someoneElse, isStarred: true, comments: ["Bookmarking this for later."])
      server.addGist(
        id: "weekend", description: "A slower weekend",
        files: ["weekend.md": "# A slower weekend\n\n- [x] Farmers market\n- [ ] Long walk\n- [ ] Call home\n"],
        updatedAt: now - hour)
      server.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [
          dailyFile(now - 3 * day): "# Notes\n\nNo tasks today.\n",
          dailyFile(now - 2 * day): "- [ ] Renew the passport\n- [ ] Book the dentist\n",
          dailyFile(now - day): "- [x] Water the plants\n- [x] Finish the outline\n",
          dailyFile(now): "- [x] Morning pages\n- [ ] Review the chapter\n- [ ] Call Mom\n",
        ],
        updatedAt: now - 30 * 60)
      server.addGist(
        id: "shape", description: "The shape of a gist",
        files: [
          "README.md": try PreviewFixtures.readingPolish,
          "Ideas.md": "# Ideas\n\n- A margin for second thoughts\n- Pages that remember where you were\n",
        ],
        updatedAt: now - 10 * 60, comments: ["Love where this is going."])
    }

    /// Pins and tags, written through the account's real preference path once the fixture signs in.
    static let preferences: [Preferences.Change] =
      [.setPinned(gistID: "shape", pinned: true), .setPinned(gistID: "words", pinned: true)]
      + [
        ("ideas", "Ideas", "#EBC85A"), ("design", "Design", "#548C80"), ("personal", "Personal", "#A88EB5"),
        ("reading", "Reading list for the long winter evenings", "#FFFFFF"), ("ink", "Ink", "#000000"),
        ("someday", "Someday", nil),
      ].map { Preferences.Change.upsertTag(id: $0.0, name: $0.1, color: $0.2) }
      + [
        ("shape", ["ideas", "design"]), ("weekend", ["personal", "someday"]), ("words", ["ideas", "reading"]),
        ("mixed", ["personal", "ink"]), ("longtitle", ["reading", "ink", "someday", "design"]),
      ].flatMap { gist, tags in tags.map { Preferences.Change.setTag(gistID: gist, tagID: $0, included: true) } }

    /// A notebook that reads like a real person's, for the README and the App Store.
    static func seedShowcase(_ server: FixtureServer, now: Date = .now) {
      let minute: TimeInterval = 60
      let day: TimeInterval = 86_400

      server.addGist(
        id: "talk", description: "SwiftUI talk notes",
        files: [
          "talk.md": "# SwiftUI talk notes\n\n1. Why native still matters\n2. Layout that adapts to the fold\n3. Widgets as front doors\n4. Questions\n",
          "demos.md": "# Demos\n\n- The launcher widget, live\n- Split view on the Duo\n",
        ],
        updatedAt: now - 13 * day,
        comments: ["Can you share the slides after?", "The widget demo would make a great opener."])
      server.addGist(
        id: "sourdough", description: "Sourdough schedule",
        files: ["sourdough.md": "# Sourdough schedule\n\n- **8 AM** Feed the starter\n- **12 PM** Mix the dough\n- **1 to 4 PM** Fold every 30 minutes\n- **Next morning** Bake at 475°F\n"],
        updatedAt: now - 5 * day)
      server.addGist(
        id: "lisbon", description: "Trip to Lisbon",
        files: ["lisbon.md": "# Trip to Lisbon\n\nA slow first day in Alfama, with the tram up to the castle at sunset.\n\nPastéis de nata in Belém, then the walk along the river to the tower.\n"],
        updatedAt: now - 2 * day)
      server.addGist(
        id: "reading", description: "Reading list",
        files: ["books.md": "# Reading list\n\n- [x] The Remains of the Day\n- [ ] Pilgrim at Tinker Creek\n- [ ] A Gentleman in Moscow\n- [ ] The Overstory\n"],
        updatedAt: now - day, isStarred: true)
      server.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [
          dailyFile(now - 2 * day): "- [x] Pick up the dry cleaning\n- [x] Send the invoice\n",
          dailyFile(now - day): "- [x] Water the plants\n- [x] Finish the talk outline\n",
          dailyFile(now): "- [x] Morning pages\n- [ ] Call Mom about Thanksgiving\n- [ ] Renew passport\n\nCoffee with Sam at 3.\n",
        ],
        updatedAt: now - 120 * minute)
      server.addGist(
        id: "garden", description: "Garden plans",
        files: ["garden.md": "# Garden plans\n\n- Tomatoes along the fence\n- Move the rosemary into the sun\n- Order seeds by February\n"],
        updatedAt: now - 90 * minute)
      server.addGist(
        id: "menu", description: "Thanksgiving menu",
        files: ["menu.md": thanksgivingMenu], updatedAt: now - 6 * minute,
        comments: ["Can we do two pies this year?"])
    }

    static let showcasePreferences: [Preferences.Change] =
      [.setPinned(gistID: "lisbon", pinned: true)]
      + [
        ("family", "Family", "#A88EB5"), ("cooking", "Cooking", "#E8A25A"), ("travel", "Travel", "#5A9BD5"),
        ("books", "Books", "#EBC85A"), ("home", "Home", "#548C80"), ("work", "Work", nil),
      ].map { Preferences.Change.upsertTag(id: $0.0, name: $0.1, color: $0.2) }
      + [
        ("menu", ["family", "cooking"]), ("garden", ["home"]), ("reading", ["books"]),
        ("lisbon", ["travel"]), ("sourdough", ["cooking"]), ("talk", ["work"]),
      ].flatMap { gist, tags in tags.map { Preferences.Change.setTag(gistID: gist, tagID: $0, included: true) } }

    private static let thanksgivingMenu =
      """
      # Thanksgiving menu

      Twelve at the table this year, and dinner's at 4.

      ## To do

      - [x] Order the turkey from Hayes Farm
      - [x] Ask Sam about the green beans
      - [ ] Brine the turkey Wednesday night
      - [ ] Borrow Mom's gravy boat

      ## Who's bringing what

      | Dish | Who |
      | --- | --- |
      | Turkey and gravy | Me |
      | Green beans | Sam |
      | Stuffing | Aunt Rose |
      | Pumpkin pie | Jess |

      > The turkey goes in at 10:30, so the oven's free for pies by 3.

      """

    private static func dailyFile(_ date: Date) -> String { DailyNote.filename(date: date) }

    private static let highlightMarkdown =
      """
      # Comment notebook

      🫧 A quiet native note, with **careful** words.

      A café moment to keep. A notebook has room for a surprise.

      `native code` stays code in Preview.


      """
      + Array(repeating: "A little room for thoughts, sketches, and the shape of a good day.", count: 20)
      .joined(separator: "\n\n")
      + "\n\n## Further down\n\nA late native passage should scroll into view.\n\n"
      + Array(repeating: "Room below, so the late passage can rest at the top of the page.", count: 24)
      .joined(separator: "\n\n") + "\n"
  }
#endif
