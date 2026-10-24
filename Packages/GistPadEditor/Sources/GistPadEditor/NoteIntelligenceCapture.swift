#if DEBUG && canImport(UIKit)
  import GistPadIntelligence
  import GistPadInterface
  import SwiftUI

  @MainActor
  public struct NoteIntelligenceCaptureView: View {
    @State private var fixture: NoteIntelligenceCaptureFixture
    @State private var presented = false
    private let savedAccentHex: String?

    public init(state: String, savedAccentHex: String? = nil) {
      _fixture = State(initialValue: NoteIntelligenceCaptureFixture(state: state))
      self.savedAccentHex = savedAccentHex
    }

    public var body: some View {
      NavigationStack {
        MarkdownEditorView(session: fixture.session, intelligence: { presented = true })
          .navigationTitle("Saturday walk")
      }
      .sheet(isPresented: $presented) {
        NoteIntelligenceSheet(
          model: fixture.model, title: "Saturday walk", filename: "Saturday.md",
          initialPromptFocus: fixture.state == "ask-keyboard",
          revealSource: { _ in presented = false }
        )
        .personalAccent(savedHex: savedAccentHex)
      }
      .task {
        await fixture.prepare()
        presented = true
      }
    }
  }

  @MainActor
  final class NoteIntelligenceCaptureFixture {
    static let source =
      "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."
    static let supportedStates: Set<String> = [
      "ask", "ask-keyboard", "answer", "edit", "review", "review-end", "readonly",
      "unavailable", "error", "edit-applied", "review-applied", "working", "edit-long-request",
    ]
    let state: String
    let session: DocumentSession
    let model: NoteIntelligenceModel

    init(state: String) {
      precondition(Self.supportedStates.contains(state), "Unknown intelligence capture state.")
      self.state = state
      let session = DocumentSession(documentID: "intelligence-fixture", text: Self.source)
      let backend = CaptureNoteModel()
      backend.available = state != "unavailable"
      backend.unverified = state == "error"
      backend.waitForCancellation = state == "working"
      session.textView.isEditable = state != "readonly"
      self.session = session
      model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "What's the plan for this morning?"
      model.editPrompt = "Fix the spelling without changing the meaning."
      if state == "edit-long-request" {
        model.editPrompt =
          """
          Fix the spelling without changing the meaning, voice or structure of this note. Keep the \
          route, departure time and cafe opening time exactly as written. Preserve the Markdown \
          heading and paragraph breaks. Explain each suggested change so I can review it before \
          applying anything. Do not add information, remove details or make the note more formal.
          """
      }
      if state.hasPrefix("edit") {
        model.action = .edit
      } else if state.hasPrefix("review") || state == "readonly" {
        model.action = .review
      }
    }

    func prepare() async {
      await model.checkAvailability()
      guard !["ask", "ask-keyboard", "unavailable"].contains(state) else { return }
      model.generate()
      guard state != "working" else { return }
      await model.task?.value
      if state == "edit-applied" { model.apply() }
      if state == "review-applied", let first = model.proposal?.comments.first {
        model.apply(commentID: first.id)
      }
    }
  }

  @MainActor
  private final class CaptureNoteModel: NoteModelBackend {
    var available = true
    var unverified = false
    var waitForCancellation = false

    func modelInfo() async throws -> NoteModelInfo {
      guard available else {
        throw NoteIntelligenceError.unavailable(
          "Turn on Apple Intelligence in Settings to use these actions.")
      }
      return NoteModelInfo(variant: "Explicit capture fixture", contextSize: 4_096)
    }

    func tokenCount(for pass: NoteModelPass) async throws -> Int { 500 }

    func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
      let spelling = NoteReplacementCandidate(
        quote: "Take teh river path.", replacement: "Take the river path.",
        reason: "Correct the spelling of “the”.")
      if pass.purpose == .review {
        return [
          spelling,
          NoteReplacementCandidate(
            quote: "before the cafe opens at 8am", replacement: "after the cafe opens at 8am",
            reason: "Leaving at 9am is after the cafe opens at 8am."),
        ]
      }
      return [spelling]
    }

    func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }

    func answer(
      for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
    ) async throws -> [ModelAnswerPart] {
      let parts = [
        ModelAnswerPart(kind: .prose, text: "You're planning a river walk, leaving at 9am."),
        ModelAnswerPart(
          kind: .quote, text: unverified ? "Invented source" : "Take teh river path."),
      ]
      onUpdate(parts)
      if waitForCancellation { try await Task.sleep(for: .seconds(300)) }
      return parts
    }
  }
#endif
