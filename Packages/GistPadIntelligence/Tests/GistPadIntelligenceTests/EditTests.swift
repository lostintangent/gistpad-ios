import Foundation
import Testing

@testable import GistPadIntelligence

@MainActor
struct EditTests {
  @Test func aChangeAppliesOnlyWhereItsTextMatchesExactlyOnce() throws {
    let literal = note("same same cafe\u{301}")
    let rejected = NoteProposal(
      snapshot: literal,
      candidates: [change("same", "different"), change("absent", "present"), change("café", "x")])
    #expect(rejected.comments.map(\.rejection) == [.ambiguous, .notFound, .notFound])
    #expect(rejected.omittedCount == 3)
    #expect(!rejected.canApply)

    let repeated = note("left same\nright same")
    let disambiguated = NoteProposal(
      snapshot: repeated,
      candidates: [
        NoteReplacementCandidate(
          quote: "same", replacement: "different", reason: "Clarify", before: "right ")
      ])
    #expect(try disambiguated.application(to: repeated).source == "left same\nright different")

    let overlap = note("abcdef safe")
    let overlapping = NoteProposal(
      snapshot: overlap,
      candidates: [change("abcd", "one"), change("cdef", "two"), change("safe", "kept")])
    #expect(overlapping.comments.prefix(2).allSatisfy { $0.rejection == .overlapping })
    #expect(try overlapping.application(to: overlap).source == "abcdef kept")
  }

  @Test func applyingKeepsEveryOtherByte() async throws {
    let mixed = note("👩🏽‍💻 bad\r\nSecond line\r\n")
    let application = try NoteProposal(
      snapshot: mixed, candidates: [change("bad", "good"), change("Second line\r\n", "")]
    ).application(to: mixed)
    #expect(application.source == "👩🏽‍💻 good\r\n")
    #expect(
      try application.mappedSelection(NSRange(location: mixed.source.utf16.count, length: 0))
        == NSRange(location: application.source.utf16.count, length: 0))

    let empty = note("")
    #expect(
      try NoteProposal(snapshot: empty, candidates: [change("", "A new paragraph")])
        .application(to: empty).source == "A new paragraph")
    #expect(
      !NoteProposal(snapshot: empty, candidates: [change("", "First"), change("", "Second")])
        .canApply)

    let fixture = NoteModelFixture()
    fixture.changes = { _ in [.insertTask(listID: 1, text: "Next")] }
    let unterminated = request("# Today\n\n- [ ] First", .edit, "Add Next")
    #expect(
      try await NoteIntelligenceEngine(backend: fixture).propose(unterminated)
        .application(to: unterminated.snapshot).source == "# Today\n\n- [ ] First\n- [ ] Next")
    fixture.changes = { _ in [.insertTask(listID: 0, text: "First")] }
    let blank = request("", .edit, "Add First")
    #expect(
      try await NoteIntelligenceEngine(backend: fixture).propose(blank)
        .application(to: blank.snapshot).source == "- [ ] First\n")
  }

  @Test func aChangedFileRefusesTheApply() throws {
    let snapshot = note("cafe\u{301}")
    let proposal = NoteProposal(snapshot: snapshot, candidates: [change(snapshot.source, "coffee")])
    for changed in [
      snapshot.edited(to: snapshot.source),
      NoteSnapshot(
        documentID: "another", sessionID: snapshot.sessionID, generation: 0,
        source: snapshot.source),
      NoteSnapshot(
        documentID: snapshot.documentID, sessionID: UUID(), generation: 0,
        source: snapshot.source),
      NoteSnapshot(
        documentID: snapshot.documentID, sessionID: snapshot.sessionID, generation: 0,
        source: "café"),
    ] {
      #expect(throws: NoteIntelligenceError.self) { try proposal.application(to: changed) }
    }
  }

  @Test func aLongFileIsCoveredEndToEndWithoutSplittingATask() async throws {
    let prose = String(repeating: "# Section\nbad 👩🏽‍💻\r\n", count: 180)
    let editor = NoteModelFixture()
    editor.contextSize = 1_536
    editor.changes = { pass in
      [.replace(change(pass.source, pass.source.replacingOccurrences(of: "bad", with: "good")))]
    }
    let fix = request(prose, .edit, "Fix bad")
    let fixed = try await NoteIntelligenceEngine(backend: editor).propose(fix)
    #expect(editor.passes.count > 1)
    #expect(editor.passes.map(\.source).joined().utf8.elementsEqual(prose.utf8))
    #expect(
      try fixed.application(to: fix.snapshot).source
        == prose.replacingOccurrences(of: "bad", with: "good"))

    let list = (1...80).map { "- [ ] Task \($0) 👩🏽‍💻\r\n" }.joined()
    let checker = NoteModelFixture()
    checker.contextSize = 512
    checker.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let all = request(list, .edit, "Check off everything")
    let checked = try await NoteIntelligenceEngine(backend: checker).propose(all)
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
    let fixture = NoteModelFixture()
    let engine = NoteIntelligenceEngine(backend: fixture)
    fixture.changes = { _ in [.insertTask(listID: 2, text: "Clean the kitchen")] }
    let recycle = "- [ ] Recycle" + newline
    #expect(
      try await engine.propose(input).application(to: input.snapshot).source.utf8.elementsEqual(
        source.replacingOccurrences(of: recycle, with: recycle + "- [ ] Clean the kitchen" + newline)
          .utf8))
    fixture.changes = { _ in [.deleteTasks(ids: [3])] }
    #expect(
      try await engine.propose(input).application(to: input.snapshot).source.utf8.elementsEqual(
        source.replacingOccurrences(of: recycle, with: "").utf8))
    for operation in [
      NoteEditOperation.insertTask(listID: 99, text: "Next"),
      .insertTask(listID: 1, text: "Next\n- [ ] Injected"), .deleteTasks(ids: [99]),
    ] {
      fixture.changes = { _ in [operation] }
      await #expect(throws: NoteIntelligenceError.invalidEdit) {
        try await engine.propose(input)
      }
    }
  }

  @Test func editChecksUnchecksAndCompletesTheRightTasks() async throws {
    let fixture = NoteModelFixture()
    let engine = NoteIntelligenceEngine(backend: fixture)
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: true)] }
    let daily = request("## 📆 2026-10-24\n\n- [ ]", .edit, "mark everything complete")
    #expect(
      try await engine.propose(daily).application(to: daily.snapshot).source
        == "## 📆 2026-10-24\n\n- [x]")
    let protected =
      "---\r\nexample: '- [ ] protected'\r\n---\r\n# Today\r\n\r\n- [ ] Read café\r\n"
      + "- [X] Already done\r\n> - [ ] A quoted task\r\n  - [ ]\r\n\r\n"
      + "```markdown\r\n- [ ] Not a real task\r\n```\r\nA sentence with `[ ]`.  \r\n"
    let everything = request(protected, .edit, "すべてのタスクを完了にして")
    #expect(everything.snapshot.tasks.map(\.isComplete) == [false, true, false, false])
    #expect(
      try await engine.propose(everything).application(to: everything.snapshot).source
        .utf8.elementsEqual(
          protected.replacingOccurrences(of: "- [ ] Read", with: "- [x] Read")
            .replacingOccurrences(of: "> - [ ] A", with: "> - [x] A")
            .replacingOccurrences(of: "  - [ ]\r\n", with: "  - [x]\r\n").utf8))

    let source = "# Today 👩🏽‍💻\r\n\r\n- [ ] Read café\r\n- [X] Done\r\n- [ ] Keep this\r\n"
    fixture.changes = { _ in [.setTaskStates(ids: [1, 2], isComplete: true)] }
    let subset = request(source, .edit, "mark the first two done")
    #expect(
      try await engine.propose(subset).application(to: subset.snapshot).source
        == source.replacingOccurrences(of: "[ ] Read", with: "[x] Read"))
    fixture.changes = { _ in [.setTaskStates(ids: nil, isComplete: false)] }
    let uncheck = request(source, .edit, "uncheck all")
    #expect(
      try await engine.propose(uncheck).application(to: uncheck.snapshot).source
        == source.replacingOccurrences(of: "[X]", with: "[ ]"))
    for ids in [[99], [1, 1], []] {
      fixture.changes = { _ in [.setTaskStates(ids: ids, isComplete: true)] }
      await #expect(throws: NoteIntelligenceError.invalidResponse) {
        try await engine.propose(request(source, .edit, "Complete it"))
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
    let diff = NoteTextDiff(before: before, after: after)
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
        String(NoteIntelligenceDiffText.attributed(runs).characters).utf8
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
}
