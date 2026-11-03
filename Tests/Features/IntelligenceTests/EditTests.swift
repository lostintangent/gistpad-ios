import Foundation
import Testing

@testable import Intelligence

@MainActor
struct EditTests {
  @Test func aChangeAppliesOnlyWhereItsTextMatchesExactlyOnce() throws {
    let literal = note("same same cafe\u{301}")
    let rejected = Review(
      snapshot: literal,
      candidates: [change("same", "different"), change("absent", "present"), change("café", "x")])
    #expect(rejected.comments.map(\.rejection) == [.ambiguous, .notFound, .notFound])
    #expect(rejected.omittedCount == 3)
    #expect(!rejected.canApply)

    let repeated = note("left same\nright same")
    let disambiguated = Review(
      snapshot: repeated,
      candidates: [
        ModelReplacement(
          quote: "same", replacement: "different", reason: "Clarify", before: "right ")
      ])
    #expect(try disambiguated.application(to: repeated).source == "left same\nright different")

    let overlap = note("abcdef safe")
    let overlapping = Review(
      snapshot: overlap,
      candidates: [change("abcd", "one"), change("cdef", "two"), change("safe", "kept")])
    #expect(overlapping.comments.prefix(2).allSatisfy { $0.rejection == .overlapping })
    #expect(try overlapping.application(to: overlap).source == "abcdef kept")
  }

  @Test func applyingKeepsEveryOtherByte() async throws {
    let mixed = note("👩🏽‍💻 bad\r\nSecond line\r\n")
    let application = try Review(
      snapshot: mixed, candidates: [change("bad", "good"), change("Second line\r\n", "")]
    ).application(to: mixed)
    #expect(application.source == "👩🏽‍💻 good\r\n")
    #expect(
      try application.mappedSelection(NSRange(location: mixed.source.utf16.count, length: 0))
        == NSRange(location: application.source.utf16.count, length: 0))

    let empty = note("")
    #expect(
      try Review(snapshot: empty, candidates: [change("", "A new paragraph")])
        .application(to: empty).source == "A new paragraph")
    #expect(
      !Review(snapshot: empty, candidates: [change("", "First"), change("", "Second")])
        .canApply)

    let fixture = FixtureModel()
    fixture.changes = { _ in [.insertTask(listID: 1, text: "Next")] }
    let unterminated = request("# Today\n\n- [ ] First", .edit, "Add Next")
    #expect(
      try await Intelligence(backend: fixture).edit(unterminated)
        .application(to: unterminated.snapshot).source == "# Today\n\n- [ ] First\n- [ ] Next")
    fixture.changes = { _ in [.insertTask(listID: 0, text: "First")] }
    let blank = request("", .edit, "Add First")
    #expect(
      try await Intelligence(backend: fixture).edit(blank)
        .application(to: blank.snapshot).source == "- [ ] First\n")
  }

  @Test func aChangedFileRefusesTheApply() throws {
    let snapshot = note("cafe\u{301}")
    let review = Review(snapshot: snapshot, candidates: [change(snapshot.source, "coffee")])
    for changed in [
      snapshot.edited(to: snapshot.source),
      FileSnapshot(
        fileID: "another", sessionID: snapshot.sessionID, generation: 0,
        source: snapshot.source),
      FileSnapshot(
        fileID: snapshot.fileID, sessionID: UUID(), generation: 0,
        source: snapshot.source),
      FileSnapshot(
        fileID: snapshot.fileID, sessionID: snapshot.sessionID, generation: 0,
        source: "café"),
    ] {
      #expect(throws: IntelligenceError.self) { try review.application(to: changed) }
    }
  }

  @Test func aLongFileIsCoveredEndToEndWithoutSplittingATask() async throws {
    let prose = String(repeating: "# Section\nbad 👩🏽‍💻\r\n", count: 180)
    let editor = FixtureModel()
    editor.contextSize = 1_536
    editor.changes = { pass in
      [.replace(change(pass.source, pass.source.replacingOccurrences(of: "bad", with: "good")))]
    }
    let fix = request(prose, .edit, "Fix bad")
    let fixed = try await Intelligence(backend: editor).edit(fix)
    #expect(editor.passes.count > 1)
    #expect(editor.passes.map(\.source).joined().utf8.elementsEqual(prose.utf8))
    #expect(
      try fixed.application(to: fix.snapshot).source
        == prose.replacingOccurrences(of: "bad", with: "good"))

    let list = (1...80).map { "- [ ] Task \($0) 👩🏽‍💻\r\n" }.joined()
    let checker = FixtureModel()
    checker.contextSize = 512
    checker.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let all = request(list, .edit, "Check off everything")
    let checked = try await Intelligence(backend: checker).edit(all)
    #expect(checker.passes.count > 1)
    #expect(checker.passes.flatMap(\.tasks).map(\.id) == Array(1...80))
    #expect(
      try checked.application(to: all.snapshot).source.utf8.elementsEqual(
        list.replacingOccurrences(of: "[ ]", with: "[x]").utf8))
  }

  @Test(arguments: ["\n", "\r\n"])
  func editAddsAndDeletesTasksInTheRightList(newline: String) async throws {
    let source =
      "---\r\ntag: daily\r\n---\r\n"
      + ["# Morning", "", "- [ ] Read café", "", "# Housework", "", "- [x] Wash 👩🏽‍💻",
        "- [ ] Recycle", "", "Keep  spacing.", ""].joined(separator: newline)
    let input = request(source, .edit, "Add a household task")
    #expect(input.snapshot.tasks.map(\.listID) == [1, 2, 2])
    let fixture = FixtureModel()
    let engine = Intelligence(backend: fixture)
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

  @Test func taskEditsDoNotShowTheModelFrontMatter() async throws {
    let prefix = "---\r\nexample: '- [ ] hidden'\r\n---\r\n\r\n"
    let body = "# Today\r\n\r\n- [ ] Visible 👩🏽‍💻\r\n"
    let fixture = FixtureModel()
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let input = request(prefix + body, .edit, "Mark every task complete")
    let review = try await Intelligence(backend: fixture).edit(input)
    #expect(input.snapshot.tasks.count == 1)
    #expect(fixture.passes.map(\.source) == [body])
    #expect(fixture.passes.flatMap(\.tasks).map(\.text) == ["- [ ] Visible 👩🏽‍💻"])
    #expect(
      try review.application(to: input.snapshot).source
        == prefix + "# Today\r\n\r\n- [x] Visible 👩🏽‍💻\r\n")
  }

  @Test func editChecksUnchecksAndCompletesTheRightTasks() async throws {
    let fixture = FixtureModel()
    let engine = Intelligence(backend: fixture)
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let daily = request("## 📆 2026-10-24\n\n- [ ]", .edit, "mark everything complete")
    #expect(
      try await engine.edit(daily).application(to: daily.snapshot).source
        == "## 📆 2026-10-24\n\n- [x]")
    let protected =
      "---\r\nexample: '- [ ] protected'\r\n---\r\n# Today\r\n\r\n- [ ] Read café\r\n"
      + "- [X] Already done\r\n> - [ ] A quoted task\r\n  - [ ]\r\n\r\n"
      + "```markdown\r\n- [ ] Not a real task\r\n```\r\nA sentence with `[ ]`.  \r\n"
    let everything = request(protected, .edit, "すべてのタスクを完了にして")
    #expect(everything.snapshot.tasks.map(\.isComplete) == [false, true, false, false])
    #expect(
      try await engine.edit(everything).application(to: everything.snapshot).source
        .utf8.elementsEqual(
          protected.replacingOccurrences(of: "- [ ] Read", with: "- [x] Read")
            .replacingOccurrences(of: "> - [ ] A", with: "> - [x] A")
            .replacingOccurrences(of: "  - [ ]\r\n", with: "  - [x]\r\n").utf8))

    let source = "# Today 👩🏽‍💻\r\n\r\n- [ ] Read café\r\n- [X] Done\r\n- [ ] Keep this\r\n"
    fixture.changes = { _ in [.setTaskStates(ids: [1, 2], isComplete: true)] }
    let subset = request(source, .edit, "mark the first two done")
    #expect(
      try await engine.edit(subset).application(to: subset.snapshot).source
        == source.replacingOccurrences(of: "[ ] Read", with: "[x] Read"))
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: false)] }
    let uncheck = request(source, .edit, "uncheck all")
    #expect(
      try await engine.edit(uncheck).application(to: uncheck.snapshot).source
        == source.replacingOccurrences(of: "[X]", with: "[ ]"))
    for ids in [[99], [1, 1], []] {
      fixture.changes = { _ in [.setTaskStates(ids: ids, isComplete: true)] }
      await #expect(throws: IntelligenceError.invalidResponse) {
        try await engine.edit(request(source, .edit, "Complete it"))
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
      #expect(
        String(DiffText.attributed(runs).characters).utf8
          .elementsEqual(source.utf8))
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
      let result = try await edited(request(source, .edit, "Edit"), [.rewrite(revision)])
      return result.replacingOccurrences(of: newline, with: "\n")
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
      let fixture = FixtureModel()
      fixture.changes = { _ in [.rewrite(revision)] }
      return try await Intelligence(backend: fixture).edit(request(source, .edit, "Edit"))
        .comments.map(\.reason)
    }
    #expect(try await reasons("A\n\nB\n\nC\n\nD", "A2\n\nB\n\nC\n\nD2") == ["", ""])
    #expect(try await reasons("A", "A\n\nB") == [""])
    #expect(try await reasons("A\n\nB\n\nC", "A\n\nC") == [""])

    let fixture = FixtureModel()
    fixture.changes = { _ in [.rewrite("# Today")] }
    let dated = request("---\ndate: 2025-01-01\n---\n# Note\n", .edit, "Rename it Today")
    let review = try await Intelligence(backend: fixture).edit(dated)
    #expect(fixture.passes.map(\.source) == ["# Note\n"])
    #expect(fixture.passes.map(\.isPart) == [false])
    #expect(
      try review.application(to: dated.snapshot).source == "---\ndate: 2025-01-01\n---\n# Today\n")

    // A rewrite too long for one reply isn't retried in parts.
    for failure in [IntelligenceError.noteTooLong, .responseTooLarge] {
      let failing = FixtureModel()
      failing.failure = failure
      await #expect(throws: failure) {
        try await Intelligence(backend: failing).edit(request("A\n\nB", .edit, "Edit"))
      }
      #expect(failing.passes.count == 1)
    }
  }

  private func edited(_ input: IntelligenceRequest, _ edits: [ModelEdit]) async throws -> String {
    let fixture = FixtureModel()
    fixture.changes = { _ in edits }
    return try await Intelligence(backend: fixture).edit(input).application(to: input.snapshot)
      .source
  }
}
