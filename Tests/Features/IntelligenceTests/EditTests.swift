import Foundation
import Testing

@testable import Intelligence

@MainActor
struct EditTests {
  @Test func aChangeAppliesOnlyWhereItsTextMatchesExactlyOnce() throws {
    let literal = note("same same cafe\u{301}")
    let rejected = Proposal(
      snapshot: literal,
      candidates: [change("same", "different"), change("absent", "present"), change("café", "x")])
    #expect(rejected.omittedCount == 3)
    #expect(!rejected.canApply)

    let repeated = note("left same\nright same")
    let disambiguated = Proposal(
      snapshot: repeated,
      candidates: [
        Proposal.Change(
          quote: "same", replacement: "different", reason: "Clarify", before: "right ")
      ])
    #expect(try disambiguated.application(to: repeated).source == "left same\nright different")

    let overlap = note("abcdef safe")
    let overlapping = Proposal(
      snapshot: overlap,
      candidates: [change("abcd", "one"), change("cdef", "two"), change("safe", "kept")])
    #expect(overlapping.changes.prefix(2).allSatisfy { $0.range == nil })
    #expect(try overlapping.application(to: overlap).source == "abcdef kept")
  }

  @Test func applyingKeepsEveryOtherByte() async throws {
    let mixed = note("👩🏽‍💻 bad\r\nSecond line\r\n")
    let application = try Proposal(
      snapshot: mixed, candidates: [change("bad", "good"), change("Second line\r\n", "")]
    ).application(to: mixed)
    #expect(application.source == "👩🏽‍💻 good\r\n")
    #expect(
      application.mappedSelection(NSRange(location: mixed.source.utf16.count, length: 0))
        == NSRange(location: application.source.utf16.count, length: 0))

    let empty = note("")
    #expect(
      try Proposal(snapshot: empty, candidates: [change("", "A new paragraph")])
        .application(to: empty).source == "A new paragraph")
    #expect(
      !Proposal(snapshot: empty, candidates: [change("", "First"), change("", "Second")])
        .canApply)

    let fixture = FixtureLanguageModel()
    fixture.changes = { _ in [.insertTask(listID: 1, text: "Next")] }
    let unterminated = request("# Today\n\n- [ ] First", "Add Next")
    #expect(
      try await IntelligenceEngine(backend: fixture).edit(unterminated)
        .application(to: unterminated.snapshot).source == "# Today\n\n- [ ] First\n- [ ] Next")
    fixture.changes = { _ in [.insertTask(listID: 0, text: "First")] }
    let blank = request("", "Add First")
    #expect(
      try await IntelligenceEngine(backend: fixture).edit(blank)
        .application(to: blank.snapshot).source == "- [ ] First\n")
  }

  @Test func aChangedFileRefusesTheApply() throws {
    let snapshot = note("cafe\u{301}")
    let proposal = Proposal(snapshot: snapshot, candidates: [change(snapshot.source, "coffee")])
    for changed in [
      snapshot.edited(to: snapshot.source),
      FileSnapshot(sessionID: UUID(), generation: 0, source: snapshot.source),
      FileSnapshot(sessionID: snapshot.sessionID, generation: 0, source: "café"),
    ] {
      #expect(throws: IntelligenceError.self) { try proposal.application(to: changed) }
    }
  }

  @Test func aLongFileIsCoveredEndToEndWithoutSplittingATask() async throws {
    let prose = String(repeating: "# Section\nbad 👩🏽‍💻\r\n", count: 180)
    let editor = FixtureLanguageModel()
    editor.contextSize = 1_536
    editor.nextFailure = IntelligenceError.insufficientContext
    editor.changes = { pass in
      [.replace(change(pass.source, pass.source.replacingOccurrences(of: "bad", with: "good")))]
    }
    let fix = request(prose, "Fix bad")
    let fixed = try await IntelligenceEngine(backend: editor).edit(fix)
    #expect(editor.passes.count > 1)
    #expect(editor.passes.first?.source.utf8.elementsEqual(prose.utf8) == true)
    #expect(editor.passes.dropFirst().map(\.source).joined().utf8.elementsEqual(prose.utf8))
    #expect(
      try fixed.application(to: fix.snapshot).source
        == prose.replacingOccurrences(of: "bad", with: "good"))

    let list = (1...80).map { "- [ ] Task \($0) 👩🏽‍💻\r\n" }.joined()
    let checker = FixtureLanguageModel()
    checker.contextSize = 512
    checker.nextFailure = IntelligenceError.insufficientContext
    checker.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let all = request(list, "Check off everything")
    let checked = try await IntelligenceEngine(backend: checker).edit(all)
    #expect(checker.passes.count > 1)
    #expect(checker.passes.dropFirst().flatMap(\.tasks).map(\.id) == Array(1...80))
    #expect(
      try checked.application(to: all.snapshot).source.utf8.elementsEqual(
        list.replacingOccurrences(of: "[ ]", with: "[x]").utf8))
  }

  @Test func editPromptKeepsRawMarkdownInsideAnUnforgeableDelimiter() throws {
    let source = "# Title\r\n\r\n```swift\r\nprint(\"Hello\")\r\n```\r\nA literal \\\\n remains.\r\n"
    let pass = ModelPass(
      purpose: .edit, instruction: "Fix the title", source: source, responseTokens: 512,
      isPart: true)
    let prompt = try OnDeviceModel.prompt(for: pass)
    #expect(prompt.contains("Request:\nFix the title"))
    #expect(prompt.contains("Note:\n````\n" + source + "\n````"))
    #expect(!prompt.contains(#"\"note\":"#))

    let whole = ModelPass(
      purpose: .edit, instruction: "Fix the title", source: source, responseTokens: 512)
    let payload = try #require(
      JSONSerialization.jsonObject(with: Data(OnDeviceModel.prompt(for: whole).utf8))
        as? [String: String])
    #expect(payload == ["note": source, "request": "Fix the title"])
  }

  @Test func moveRequiresOneIntactItemInADifferentSection() throws {
    let source = """
      ## Kitchen

      - [ ] Paint the window trim
      - [ ] Replace the trap

      ## Entry

      - [ ] Patch the wall
      """
    let snapshot = note(source)
    let moved = Proposal(
      snapshot: snapshot,
      scopedCandidates: [
        (change("- [ ] Paint the window trim\n", ""), NSRange(location: 0, length: source.utf16.count)),
        (change("- [ ] Patch the wall", "- [ ] Paint the window trim\n- [ ] Patch the wall"),
          NSRange(location: 0, length: source.utf16.count)),
      ],
      safetyInstruction: "move Paint the window trim from Kitchen to Entry")
    #expect(
      try moved.application(to: snapshot).source
        == source.replacingOccurrences(of: "- [ ] Paint the window trim\n", with: "")
          .replacingOccurrences(
            of: "- [ ] Patch the wall", with: "- [ ] Paint the window trim\n- [ ] Patch the wall"))

    for edits in [
      [change("- [ ] Paint the window trim\n", "")],
      [change("- [ ] Patch the wall", "- [ ] Paint the window trim\n- [ ] Patch the wall")],
      [change("- [ ] Replace the trap", "- [ ] Replace the trap\n- [ ] Paint the window trim"),
        change("- [ ] Paint the window trim\n", "")],
    ] {
      let proposal = Proposal(
        snapshot: note(source),
        scopedCandidates: edits.map {
          ($0, NSRange(location: 0, length: source.utf16.count))
        },
        safetyInstruction: "move Paint the window trim from Kitchen to Entry")
      #expect(throws: IntelligenceError.invalidEdit) {
        try proposal.application(to: proposal.snapshot)
      }
    }
  }

  @Test func movingADateDoesNotRequireAListItem() throws {
    let snapshot = note("## Next check\n\nThe offline-pipe retest is scheduled for November 6.\n")
    let proposal = Proposal(
      snapshot: snapshot,
      scopedCandidates: [
        (change("November 6", "November 9"),
          NSRange(location: 0, length: snapshot.source.utf16.count))
      ],
      safetyInstruction: "move the offline-pipe retest from November 6 to November 9")
    #expect(
      try proposal.application(to: snapshot).source
        == "## Next check\n\nThe offline-pipe retest is scheduled for November 9.\n")
  }

  @Test(arguments: ["\n", "\r\n"])
  func misplacedPureInsertionsMoveToTheRequestedMarkdownAnchor(newline: String) throws {
    let cases: [(String, String, String, String)] = [
      (
        "### Launch sync\n\nOriginal discussion.\n\nFinal note.",
        "### Launch sync\n\nOriginal discussion.\n\nFinal note.\n\nThe team agreed to ship.",
        "add a one-sentence summary under the Launch sync heading",
        "### Launch sync\n\nThe team agreed to ship.\n\nOriginal discussion.\n\nFinal note."
      ),
      (
        "### Options\n\n| Flag | Meaning |\n| --- | --- |\n"
          + "| `-r` | Reverse order |\n| `-i` | Ignore case |",
        "### Options\n\n| Flag | Meaning |\n| --- | --- |\n"
          + "| `-n` | Number lines |\n| `-r` | Reverse order |\n| `-i` | Ignore case |",
        "add a row to the Options table for a -n flag that numbers each line",
        "### Options\n\n| Flag | Meaning |\n| --- | --- |\n"
          + "| `-r` | Reverse order |\n| `-i` | Ignore case |\n| `-n` | Number lines |"
      ),
    ]
    for (before, misplaced, instruction, expected) in cases {
      let source = before.replacingOccurrences(of: "\n", with: newline)
      let revised = misplaced.replacingOccurrences(of: "\n", with: newline)
      let candidates = try Proposal.Change.lineChanges(
        in: source, visible: NSRange(location: 0, length: source.utf16.count),
        revised: revised)
      let blocks = EditBlock.indexed(in: source)
      let anchor = try #require(
        instruction.contains("summary")
          ? blocks.first { $0.kind == .heading }
          : blocks.last { $0.kind == .tableRow })
      let insertion = try #require(OnDeviceModel.relocatedInsertion(
        from: candidates, for: anchor, instruction: instruction, section: source))
      let snapshot = note(source)
      let proposal = Proposal(
        snapshot: snapshot, scopedCandidates: [(insertion, anchor.range)])
      #expect(
        try proposal.application(to: snapshot).source
          == expected.replacingOccurrences(of: "\n", with: newline))
      #expect(change("Keep", "Kept\n\nNew").insertedText == nil)
    }
  }

  @Test func editSectionsHoldOnlyTheTextDirectlyUnderEachHeading() {
    let source = """
      # Project

      Intro.

      ## Setup

      Setup notes.

      ### Install

      Install steps.

      ### Options

      | Flag | Meaning |
      | -i | Ignore case |

      ## Next check

      Retest in November.
      """
    let sections = EditSection.indexed(in: source)
    #expect(sections.map(\.title) == [
      "# Project", "## Setup", "### Install", "### Options", "## Next check",
    ])
    #expect(sections.map(\.level) == [1, 2, 3, 3, 2])
    #expect(sections.map { (source as NSString).substring(with: $0.directRange) } == [
      "# Project\n\nIntro.", "## Setup\n\nSetup notes.", "### Install\n\nInstall steps.",
      "### Options\n\n| Flag | Meaning |\n| -i | Ignore case |", "## Next check\n\nRetest in November.",
    ])
  }

  @Test func scopedEditsSpliceOnlyVerifiedBodyRanges() async throws {
    let prefix = "---\r\nsecret: 👩🏽‍💻\r\n---\r\n"
    let body = "# Reading\r\n\r\n- Paper Observatory\r\n- River Engine\r\n\r\n## Notes\r\n\r\nKeep this.\r\n"
    let input = request(prefix + body, "Move Paper Observatory after River Engine")
    let fixture = FixtureLanguageModel()
    fixture.changes = { pass in
      let blocks = EditBlock.indexed(in: pass.source)
      let source = blocks.first { $0.text == "- Paper Observatory" }!
      let destination = blocks.first { $0.text == "- River Engine" }!
      let removed = NSRange(
        location: source.range.location, length: destination.range.location - source.range.location)
      return [
        .replaceRegion(
          removed, change((pass.source as NSString).substring(with: removed), "")),
        .rewriteRegion(destination.range, revised: "- River Engine\n- Paper Observatory"),
      ]
    }
    let proposal = try await IntelligenceEngine(backend: fixture).edit(input)
    #expect(fixture.passes.map(\.source) == [body])
    #expect(proposal.changes.count == 2)
    #expect(proposal.omittedCount == 0)
    #expect(
      try proposal.application(to: input.snapshot).source
        == prefix + "# Reading\r\n\r\n- River Engine\r\n- Paper Observatory\r\n\r\n## Notes\r\n\r\nKeep this.\r\n")

    fixture.changes = { pass in
      let heading = EditBlock.indexed(in: pass.source).first { $0.text == "## Notes" }!
      return [
        .rewriteRegion(
          heading.range, revised: "## Notes\n\nA new introduction for the section.")
      ]
    }
    let inserted = try await IntelligenceEngine(backend: fixture).edit(input)
    #expect(
      try inserted.application(to: input.snapshot).source
        == prefix + body.replacingOccurrences(
          of: "## Notes\r\n\r\n", with: "## Notes\r\n\r\nA new introduction for the section.\r\n\r\n"))
  }

  @Test func aScopedHunkKeepsRepeatedTextOutsideTheSelectedBlock() async throws {
    let input = request("# First\n\nKeep this.\n\n# Second\n\nKeep this.\n", "Change the second note")
    let target = (input.snapshot.source as NSString).range(of: "Keep this.", options: .backwards)
    let fixture = FixtureLanguageModel()
    fixture.changes = { _ in
      [.replaceRegion(target, change("Keep this.", "Change this."))]
    }
    let proposal = try await IntelligenceEngine(backend: fixture).edit(input)
    #expect(proposal.omittedCount == 0)
    #expect(
      try proposal.application(to: input.snapshot).source
        == "# First\n\nKeep this.\n\n# Second\n\nChange this.\n")

    fixture.changes = { _ in
      [.replaceRegion(target, change("Other text.", "Change this."))]
    }
    await #expect(throws: IntelligenceError.invalidResponse) {
      try await IntelligenceEngine(backend: fixture).edit(input)
    }
  }

  @Test(arguments: ["\n", "\r\n"])
  func editAddsAndDeletesTasksInTheRightList(newline: String) async throws {
    let source =
      "---\r\ntag: daily\r\n---\r\n"
      + ["# Morning", "", "- [ ] Read café", "", "# Housework", "", "- [x] Wash 👩🏽‍💻",
        "- [ ] Recycle", "", "Keep  spacing.", ""].joined(separator: newline)
    let input = request(source, "Add a household task")
    #expect(input.snapshot.tasks.map(\.listID) == [1, 2, 2])
    let fixture = FixtureLanguageModel()
    let engine = IntelligenceEngine(backend: fixture)
    fixture.changes = { _ in [.insertTask(listID: 2, text: "Clean the kitchen")] }
    let recycle = "- [ ] Recycle" + newline
    #expect(
      try await engine.edit(input).application(to: input.snapshot).source.utf8.elementsEqual(
        source.replacingOccurrences(of: recycle, with: recycle + "- [ ] Clean the kitchen" + newline)
          .utf8))
    fixture.changes = { _ in [.deleteTasks(ids: [3])] }
    #expect(
      try await engine.edit(input).application(to: input.snapshot).source.utf8.elementsEqual(
        source.replacingOccurrences(of: recycle, with: "").utf8))
    for operation in [
      ModelEdit.insertTask(listID: 99, text: "Next"),
      .insertTask(listID: 1, text: "Next\n- [ ] Injected"), .deleteTasks(ids: [99]),
    ] {
      fixture.changes = { _ in [operation] }
      await #expect(throws: IntelligenceError.invalidEdit) {
        try await engine.edit(input)
      }
    }
  }

  @Test func editChecksUnchecksAndCompletesTheRightTasks() async throws {
    let fixture = FixtureLanguageModel()
    let engine = IntelligenceEngine(backend: fixture)
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let daily = request("## 📆 2026-10-24\n\n- [ ]", "mark everything complete")
    #expect(
      try await engine.edit(daily).application(to: daily.snapshot).source
        == "## 📆 2026-10-24\n\n- [x]")
    let protected =
      "---\r\nexample: '- [ ] protected'\r\n---\r\n# Today\r\n\r\n- [ ] Read café\r\n"
      + "- [X] Already done\r\n> - [ ] A quoted task\r\n  - [ ]\r\n\r\n"
      + "```markdown\r\n- [ ] Not a real task\r\n```\r\nA sentence with `[ ]`.  \r\n"
    let everything = request(protected, "すべてのタスクを完了にして")
    #expect(everything.snapshot.tasks.map(\.isComplete) == [false, true, false, false])
    #expect(
      try await engine.edit(everything).application(to: everything.snapshot).source
        .utf8.elementsEqual(
          protected.replacingOccurrences(of: "- [ ] Read", with: "- [x] Read")
            .replacingOccurrences(of: "> - [ ] A", with: "> - [x] A")
            .replacingOccurrences(of: "  - [ ]\r\n", with: "  - [x]\r\n").utf8))

    let source = "# Today 👩🏽‍💻\r\n\r\n- [ ] Read café\r\n- [X] Done\r\n- [ ] Keep this\r\n"
    fixture.changes = { _ in [.setTaskStates(ids: [1, 2], isComplete: true)] }
    let subset = request(source, "mark the first two done")
    #expect(
      try await engine.edit(subset).application(to: subset.snapshot).source
        == source.replacingOccurrences(of: "[ ] Read", with: "[x] Read"))
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: false)] }
    let uncheck = request(source, "uncheck all")
    #expect(
      try await engine.edit(uncheck).application(to: uncheck.snapshot).source
        == source.replacingOccurrences(of: "[X]", with: "[ ]"))
    for ids in [[99], [1, 1], []] {
      fixture.changes = { _ in [.setTaskStates(ids: ids, isComplete: true)] }
      await #expect(throws: IntelligenceError.invalidResponse) {
        try await engine.edit(request(source, "Complete it"))
      }
    }
  }

  @Test(arguments: [
    ("Take teh river path.", "Take the river path.", "teh", "the"),
    ("  One,\r\n\t“two”  ", "  One.\r\n\t“two”\t", ",  ", ".\t"),
    ("A cafe\u{301}.", "A café.", "cafe\u{301}", "café"),
    ("", "A new paragraph.", "", "A new paragraph."),
    ("Remove this paragraph.", "", "Remove this paragraph.", ""),
    ("No change.\r\n", "No change.\r\n", "", ""),
    ("👩🏽‍💻 [cafe\u{301}](url)\r\n*old* `code`", "👩🏽‍💻 [coffee](url)\r\n*new* `code`", nil, nil),
    ("今日は川を歩きます。", "今日は公園を歩きます。", nil, nil),
    ("قراءة الملاحظة", "كتابة الملاحظة", nil, nil),
    ("same one same two same", "same two same one same", nil, nil),
  ] as [(String, String, String?, String?)])
  func theDiffMarksOnlyTheChangedWordsAndKeepsLiteralBytes(
    before: String, after: String, removed: String?, added: String?
  ) {
    let diff = TextDiff(before: before, after: after)
    if let removed {
      #expect(
        diff.before.filter { $0.kind == .removed }.map(\.text).joined().utf8
          .elementsEqual(removed.utf8))
    }
    if let added {
      #expect(
        diff.after.filter { $0.kind == .added }.map(\.text).joined().utf8
          .elementsEqual(added.utf8))
    }
    #expect(!diff.before.contains { $0.kind == .added })
    #expect(!diff.after.contains { $0.kind == .removed })
    for (source, runs) in [(before, diff.before), (after, diff.after)] {
      #expect(runs.map(\.text).joined().utf8.elementsEqual(source.utf8))
      var boundaries: Set<Int> = [0]
      var offset = 0
      for character in source {
        offset += String(character).utf8.count
        boundaries.insert(offset)
      }
      offset = 0
      for run in runs {
        offset += run.text.utf8.count
        #expect(boundaries.contains(offset))
      }
    }
  }

  @Test(arguments: ["\n", "\r\n"])
  func aRevisedNoteChangesOnlyItsChangedLines(newline: String) async throws {
    func revised(_ text: String, _ revision: String) async throws -> String {
      let source = text.replacingOccurrences(of: "\n", with: newline)
      let fixture = FixtureLanguageModel()
      fixture.changes = rewrite(revision)
      let input = request(source, "Edit")
      return try await IntelligenceEngine(backend: fixture).edit(input)
        .application(to: input.snapshot).source.replacingOccurrences(of: newline, with: "\n")
    }
    let daily = "---\ntags: [daily]\n---\n# Today\n\n- [ ] Coffee\n- [ ] Walk\n\nNotes\n"
    #expect(
      try await revised(daily, "# Today\n\n- [x] Coffee\n- [ ] Walk\n\nNotes")
        == "---\ntags: [daily]\n---\n# Today\n\n- [x] Coffee\n- [ ] Walk\n\nNotes\n")
    #expect(
      try await revised(daily, "# Today\n\n- [ ] Coffee\n- [ ] Walk\n- [ ] Read\n\nNotes\n\n")
        == "---\ntags: [daily]\n---\n# Today\n\n- [ ] Coffee\n- [ ] Walk\n- [ ] Read\n\nNotes\n")
    #expect(
      try await revised(
        daily, "```markdown\nHi\n\n# Today\n\n- [ ] Coffee\n- [ ] Walk\n\nNotes\n```")
        == "---\ntags: [daily]\n---\nHi\n\n# Today\n\n- [ ] Coffee\n- [ ] Walk\n\nNotes\n")
    #expect(
      try await revised(daily, "# Today\n\n- [ ] Coffee\n\nNotes")
        == "---\ntags: [daily]\n---\n# Today\n\n- [ ] Coffee\n\nNotes\n")
    #expect(
      try await revised(daily, #"# Today\n\n- [x] Coffee\n- [ ] Walk\n\nNotes\n"}"#)
        == "---\ntags: [daily]\n---\n# Today\n\n- [x] Coffee\n- [ ] Walk\n\nNotes\n")
    #expect(try await revised(#"Use \n here"#, #"Use \n there"#) == #"Use \n there"#)
    #expect(try await revised("One\n\nTwo\n\nThree", "One\n\nThree") == "One\n\nThree")
    #expect(try await revised("One\n\nTwo\n\nThree", "Two\n\nThree") == "Two\n\nThree")
    #expect(try await revised("- [ ] A\nKeep  \n", "- [x] A\nKeep") == "- [x] A\nKeep  \n")
    #expect(
      try await revised(
        "# Title\n\nBody\n\n## Next\n\n- x\n",
        "# Title\n\nSum.\n\nBody\n\n## Next\n\n- x\n\n## Risks\n\n- y")
        == "# Title\n\nSum.\n\nBody\n\n## Next\n\n- x\n\n## Risks\n\n- y\n")
    #expect(try await revised("", "Hello") == "Hello\n")
    #expect(
      try await revised("```swift\nlet a = 1\n```", "```swift\nlet a = 2\n```")
        == "```swift\nlet a = 2\n```")
    #expect(
      try await revised("- [ ] A\n- [ ] B\n\nDone", "- [ ] A\n\n- [x] B\n\n- [ ] C\n\nDone")
        == "- [ ] A\n- [x] B\n- [ ] C\n\nDone")
    #expect(try await revised("- A\n\n- B\n", "- A\n\n- B\n\n- C") == "- A\n\n- B\n\n- C\n")
    #expect(
      try await revised("Intro\n- It's  \"here\"  \n", "Intro\n- It’s “here”\n- New")
        == "Intro\n- It's  \"here\"  \n- New\n")
    await #expect(throws: IntelligenceError.unsafeEdit) {
      try await revised("Text\n", "Text\n\n```markdown\nMore")
    }
    await #expect(throws: IntelligenceError.unsafeEdit) {
      try await revised("Keep me", "\n\n")
    }
  }

  @Test func aRevisionLetsItsDiffSpeakAndNeverSeesFrontMatter() async throws {
    func reasons(_ source: String, _ revision: String) async throws -> [String] {
      let fixture = FixtureLanguageModel()
      fixture.changes = rewrite(revision)
      return try await IntelligenceEngine(backend: fixture).edit(request(source, "Edit"))
        .changes.map(\.reason)
    }
    #expect(try await reasons("A\n\nB\n\nC\n\nD", "A2\n\nB\n\nC\n\nD2") == ["", ""])
    #expect(try await reasons("A", "A\n\nB") == [""])
    #expect(try await reasons("A\n\nB\n\nC", "A\n\nC") == [""])

    let fixture = FixtureLanguageModel()
    fixture.changes = rewrite("# Today")
    let dated = request("---\ndate: 2025-01-01\n---\n# Note\n", "Rename it Today")
    let proposal = try await IntelligenceEngine(backend: fixture).edit(dated)
    #expect(fixture.passes.map(\.source) == ["# Note\n"])
    #expect(fixture.passes.map(\.isPart) == [false])
    #expect(
      try proposal.application(to: dated.snapshot).source == "---\ndate: 2025-01-01\n---\n# Today\n")

    // A rewrite too long for one reply isn't retried in parts.
    let failing = FixtureLanguageModel()
    failing.failure = IntelligenceError.responseTooLarge
    await #expect(throws: IntelligenceError.responseTooLarge) {
      try await IntelligenceEngine(backend: failing).edit(request("A\n\nB", "Edit"))
    }
    #expect(failing.passes.count == 1)
  }
}
