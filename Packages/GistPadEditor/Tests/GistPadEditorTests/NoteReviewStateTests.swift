#if canImport(UIKit)
  import GistPadIntelligence
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct NoteReviewStateTests {
    @Test func openingAndCheckingTheSharedStateDoesNotGenerateOrChangeTheNote() async {
      let session = DocumentSession(documentID: "review-open", text: "bad and typo", generation: 4)
      let backend = ReviewBackend()
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      let inspector = review
      await review.model.checkAvailability()
      await inspector.model.checkAvailability()
      #expect(inspector === review)
      #expect(review.model.available)
      #expect(!review.hasReview)
      #expect(!review.isRunning)
      #expect(review.model.proposal == nil)
      #expect(backend.calls == 0)
      #expect(session.text == "bad and typo")
      #expect(session.generation == 4)
    }

    @Test func askAndEditRequestsCannotEraseTheSharedReview() async throws {
      let session = DocumentSession(documentID: "review-independent", text: "bad and typo")
      let backend = ReviewBackend()
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      review.generate()
      await review.task?.value
      let ids = try #require(review.model.proposal).comments.map(\.id)
      review.closePresentation()
      let inspector = review
      let sheet = NoteIntelligenceModel(
        session: session, backend: ReviewBackend(), isCurrent: { true })
      sheet.askPrompt = "Explain this note"
      await sheet.checkAvailability()
      sheet.generate()
      await sheet.task?.value
      sheet.action = .edit
      sheet.clearResults()
      sheet.editPrompt = "Fix the wording"
      sheet.generate()
      await sheet.task?.value
      sheet.cancel()
      sheet.clearResults()
      #expect(inspector === review)
      #expect(review.hasReview)
      #expect(review.model.proposal?.comments.map(\.id) == ids)
      #expect(backend.calls == 1)
      #expect(backend.lastPass?.purpose == .review)
      #expect(backend.lastPass?.instruction.isEmpty == true)
      #expect(session.text == "bad and typo")
      #expect(session.generation == 0)
    }

    @Test func individualApplyRebasesTheRemainingSuggestionAndHidesTheLastOne() async throws {
      let session = DocumentSession(documentID: "review-apply", text: "bad and typo")
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let backend = ReviewBackend()
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      review.generate()
      await review.task?.value
      let original = try #require(review.model.proposal)
      #expect(changes == 0)
      review.apply(commentID: original.comments[0].id)
      let remaining = try #require(review.model.proposal)
      #expect(review.hasReview)
      #expect(!review.isStale)
      #expect(review.canApply)
      #expect(remaining.comments.map(\.id) == [original.comments[1].id])
      #expect(remaining.comments[0].range == (session.text as NSString).range(of: "typo"))
      review.apply(commentID: remaining.comments[0].id)
      #expect(!review.hasReview)
      #expect(review.model.proposal?.comments.isEmpty == true)
      #expect(review.model.appliedCount == 2)
      #expect(review.model.errorMessage == nil)
      #expect(backend.calls == 1)
      #expect(session.text == "much better and word")
      #expect(session.generation == 2)
      #expect(changes == 2)
    }

    @Test func dismissalPreservesTheOtherAnchorsWithoutChangingSource() async throws {
      let source = "bad and typo"
      let session = DocumentSession(documentID: "review-dismiss", text: source)
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let backend = ReviewBackend()
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      review.generate()
      await review.task?.value
      let original = try #require(review.model.proposal)
      review.dismiss(commentID: original.comments[0].id)
      let remaining = try #require(review.model.proposal)
      #expect(review.hasReview)
      #expect(remaining.snapshot == original.snapshot)
      #expect(remaining.comments.map(\.id) == [original.comments[1].id])
      #expect(remaining.comments[0].range == original.comments[1].range)
      #expect(remaining.comments[0].canApply)
      review.dismiss(commentID: remaining.comments[0].id)
      #expect(!review.hasReview)
      #expect(review.model.errorMessage == nil)
      #expect(backend.calls == 1)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(changes == 0)
    }

    @Test func adviceAndUnanchoredSuggestionsCanBeDismissedWithoutApply() async throws {
      let session = DocumentSession(documentID: "review-advice", text: "bad and typo")
      let backend = ReviewBackend()
      backend.candidates = [
        NoteReplacementCandidate(quote: "bad", replacement: nil, reason: "Explain this term."),
        NoteReplacementCandidate(quote: "missing", replacement: "word", reason: "Unanchored"),
      ]
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      review.generate()
      await review.task?.value
      let proposal = try #require(review.model.proposal)
      #expect(!review.canApply)
      #expect(proposal.comments.count == 2)
      for comment in proposal.comments { review.dismiss(commentID: comment.id) }
      #expect(!review.hasReview)
      #expect(review.model.errorMessage == nil)
      #expect(session.generation == 0)
    }

    @Test func anUnknownDismissalShowsAnErrorAndKeepsTheRealSuggestions() async throws {
      let session = DocumentSession(documentID: "review-unknown", text: "bad and typo")
      let review = NoteReviewState(
        session: session, backend: ReviewBackend(), isCurrent: { true })
      review.generate()
      await review.task?.value
      let ids = try #require(review.model.proposal).comments.map(\.id)
      review.dismiss(commentID: UUID())
      #expect(review.hasReview)
      #expect(review.model.errorMessage?.isEmpty == false)
      #expect(review.model.proposal?.comments.map(\.id) == ids)
      #expect(session.generation == 0)
    }

    @Test(arguments: ["empty", "failure", "unavailable"])
    func emptyAndFailedResultsRemainVisibleUntilThePresentationCloses(outcome: String) async {
      let session = DocumentSession(documentID: "review-terminal", text: "bad and typo")
      let backend = ReviewBackend()
      if outcome == "empty" { backend.candidates = [] }
      if outcome == "failure" { backend.failure = .refused }
      if outcome == "unavailable" { backend.available = false }
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      review.generate()
      #expect(review.hasReview)
      #expect(review.isRunning)
      await review.task?.value
      #expect(review.hasReview)
      #expect(!review.isRunning)
      if outcome == "empty" {
        #expect(review.model.proposal?.comments.isEmpty == true)
        #expect(review.model.errorMessage == nil)
      } else if outcome == "failure" {
        #expect(review.model.proposal == nil)
        #expect(review.model.errorMessage?.isEmpty == false)
      } else {
        #expect(review.model.availabilityReason?.isEmpty == false)
        #expect(backend.calls == 0)
      }
      review.closePresentation()
      #expect(!review.hasReview)
      #expect(review.model.proposal == nil)
      #expect(review.model.errorMessage == nil)
      #expect(session.text == "bad and typo")
      #expect(session.generation == 0)
    }

    @Test func cancellingDuringAvailabilityImmediatelyRemovesReviewAndNeverGenerates() async {
      let session = DocumentSession(documentID: "review-availability-cancel", text: "bad and typo")
      let backend = ReviewBackend()
      backend.suspendAvailability = true
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      await withCheckedContinuation { started in
        backend.onAvailability = { started.resume() }
        review.generate()
      }
      let pending = review.task
      review.clear()
      #expect(!review.hasReview)
      #expect(!review.isRunning)
      backend.resumeAvailability()
      await pending?.value
      #expect(!review.hasReview)
      #expect(review.model.proposal == nil)
      #expect(review.model.errorMessage == nil)
      #expect(backend.calls == 0)
      #expect(session.generation == 0)
    }

    @Test func aLateCancelledGenerationCannotRepopulateOrEraseANewerReview() async throws {
      let session = DocumentSession(documentID: "review-late", text: "bad and typo")
      let backend = ReviewBackend()
      backend.suspendReplacements = true
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      await withCheckedContinuation { started in
        backend.onReplacements = { started.resume() }
        review.generate()
      }
      let oldTask = review.task
      let oldModel = review.model
      review.closePresentation()
      #expect(review.hasReview)
      #expect(review.isRunning)
      review.clear()
      #expect(!review.hasReview)
      #expect(review.model !== oldModel)
      #expect(review.model.proposal == nil)
      backend.suspendReplacements = false
      review.generate()
      await review.task?.value
      let newIDs = try #require(review.model.proposal).comments.map(\.id)
      backend.resumeReplacements()
      await oldTask?.value
      #expect(review.hasReview)
      #expect(review.model.proposal?.comments.map(\.id) == newIDs)
      #expect(review.model.notice == nil)
      #expect(review.model.errorMessage == nil)
      #expect(backend.calls == 2)
      #expect(session.text == "bad and typo")
      #expect(session.generation == 0)
    }

    @Test func sourceChangesMakeApplyStaleButStillAllowDismissal() async throws {
      let session = DocumentSession(documentID: "review-stale", text: "bad and typo")
      let review = NoteReviewState(
        session: session, backend: ReviewBackend(), isCurrent: { true })
      review.generate()
      await review.task?.value
      let proposal = try #require(review.model.proposal)
      try session.apply(
        SourceMutation(range: NSRange(location: 0, length: 3), expected: "bad", replacement: "new"),
        documentID: session.documentID, generation: 0)
      #expect(review.isStale)
      #expect(!review.canApply)
      review.apply(commentID: proposal.comments[0].id)
      #expect(review.model.errorMessage?.isEmpty == false)
      #expect(session.text == "new and typo")
      #expect(session.generation == 1)
      for comment in proposal.comments { review.dismiss(commentID: comment.id) }
      #expect(!review.hasReview)
      #expect(session.generation == 1)
    }

    @Test func losingOwnershipRejectsGenerationAndApplyThenClearRemovesResults() async throws {
      let session = DocumentSession(documentID: "review-account", text: "bad and typo")
      var current = true
      let backend = ReviewBackend()
      let review = NoteReviewState(
        session: session, backend: backend, isCurrent: { current })
      review.generate()
      await review.task?.value
      let comment = try #require(review.model.proposal?.comments.first)
      current = false
      #expect(review.isStale)
      #expect(!review.canApply)
      review.apply(commentID: comment.id)
      #expect(review.model.errorMessage?.isEmpty == false)
      review.generate()
      await review.task?.value
      #expect(review.model.errorMessage?.isEmpty == false)
      #expect(backend.calls == 1)
      review.clear()
      #expect(!review.hasReview)
      #expect(review.model.proposal == nil)
      #expect(session.generation == 0)
    }

    @Test func aReadOnlyNoteCanBeReviewedAndDismissedButNotChanged() async throws {
      let session = DocumentSession(documentID: "review-readonly", text: "bad and typo")
      session.textView.isEditable = false
      let backend = ReviewBackend()
      let review = NoteReviewState(session: session, backend: backend, isCurrent: { true })
      review.generate()
      await review.task?.value
      let proposal = try #require(review.model.proposal)
      #expect(review.hasReview)
      #expect(!review.canApply)
      review.apply(commentID: proposal.comments[0].id)
      #expect(review.model.errorMessage?.isEmpty == false)
      for comment in proposal.comments { review.dismiss(commentID: comment.id) }
      #expect(!review.hasReview)
      #expect(backend.calls == 1)
      #expect(session.text == "bad and typo")
      #expect(session.generation == 0)
    }
  }

  @MainActor
  private final class ReviewBackend: NoteModelBackend {
    var available = true
    var failure: NoteIntelligenceError?
    var suspendAvailability = false
    var suspendReplacements = false
    var onAvailability: (() -> Void)?
    var onReplacements: (() -> Void)?
    var calls = 0
    var lastPass: NoteModelPass?
    private var availability: CheckedContinuation<Void, Never>?
    private var replacements: CheckedContinuation<Void, Never>?
    var candidates = [
      NoteReplacementCandidate(quote: "bad", replacement: "much better", reason: "Clarity"),
      NoteReplacementCandidate(quote: "typo", replacement: "word", reason: "Spelling"),
    ]

    func modelInfo() async throws -> NoteModelInfo {
      if suspendAvailability {
        await withCheckedContinuation {
          availability = $0
          onAvailability?()
        }
      }
      guard available else { throw NoteIntelligenceError.unavailable("Model not ready") }
      return NoteModelInfo(variant: "Fake Review", contextSize: 4_096)
    }

    func tokenCount(for pass: NoteModelPass) async throws -> Int { 100 }

    func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
      calls += 1
      lastPass = pass
      if suspendReplacements {
        await withCheckedContinuation {
          replacements = $0
          onReplacements?()
        }
      }
      if let failure { throw failure }
      return candidates
    }

    func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }

    func answer(
      for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
    ) async throws -> [ModelAnswerPart] {
      [ModelAnswerPart(kind: .prose, text: "The note contains two wording suggestions.")]
    }

    func resumeAvailability() {
      suspendAvailability = false
      availability?.resume()
      availability = nil
    }

    func resumeReplacements() {
      replacements?.resume()
      replacements = nil
    }
  }
#endif
