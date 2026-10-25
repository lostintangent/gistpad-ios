#if canImport(UIKit)
  import GistPadIntelligence
  import Observation
  import UIKit

  @MainActor
  @Observable
  public final class NoteReviewState {
    public private(set) var hasReview = false
    private(set) var model: NoteIntelligenceModel
    private var isPreparing = false
    @ObservationIgnored private let makeModel: @MainActor () -> NoteIntelligenceModel
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    public init(
      session: DocumentSession, backend: (any NoteModelBackend)? = nil,
      isCurrent: @escaping @MainActor () -> Bool
    ) {
      let makeModel: @MainActor () -> NoteIntelligenceModel = {
        let model = NoteIntelligenceModel(
          session: session, backend: backend ?? AppleNoteModel(), isCurrent: isCurrent)
        model.action = .review
        return model
      }
      self.makeModel = makeModel
      model = makeModel()
    }

    init(model: NoteIntelligenceModel) {
      precondition(model.action == .review)
      self.model = model
      makeModel = model.modelFactory(action: .review)
      hasReview = model.isRunning || model.hasResults || model.errorMessage != nil
    }

    public var isRunning: Bool { isPreparing || model.isRunning }
    public var available: Bool { model.available }
    public var canGenerate: Bool { !isPreparing && model.canGenerate }
    public var availabilityReason: String? { model.availabilityReason }
    public var progress: NoteIntelligenceProgress? { model.progress }
    public var proposal: NoteProposal? { model.proposal }
    public var snapshot: NoteSnapshot? { model.snapshot }
    public var isStale: Bool { model.isStale }
    public var canApply: Bool { hasReview && !isPreparing && model.canApply }
    public var canDismiss: Bool { hasReview && !isRunning }
    public var errorMessage: String? { model.errorMessage }
    public var notice: String? { model.notice }
    public var appliedCount: Int { model.appliedCount }
    public var applyFeedback: Int { model.applyFeedback }

    public func checkAvailability() async {
      await model.checkAvailability()
    }

    public func generate() {
      guard !isRunning else { return }
      hasReview = true
      isPreparing = true
      model.clearResults()
      let model = model
      let id = UUID()
      generationID = id
      task = Task { [weak self] in
        await model.checkAvailability()
        guard !Task.isCancelled, self?.generationID == id else { return }
        self?.isPreparing = false
        guard model.available else {
          self?.task = nil
          return
        }
        guard model.canGenerate else {
          model.errorMessage = NoteIntelligenceError.staleSnapshot.localizedDescription
          self?.task = nil
          return
        }
        model.generate()
        await model.task?.value
        guard self?.generationID == id else { return }
        self?.task = nil
      }
    }

    public func apply(commentID: UUID) {
      model.apply(commentID: commentID)
      if model.proposal?.comments.isEmpty == true { hasReview = false }
    }

    public func dismiss(commentID: UUID) {
      guard canDismiss, let proposal = model.proposal else {
        model.errorMessage = NoteIntelligenceError.noApplicableChanges.localizedDescription
        return
      }
      do {
        model.proposal = try proposal.dismissing(commentID: commentID)
        model.errorMessage = nil
        if model.proposal?.comments.isEmpty == true { hasReview = false }
      } catch {
        model.errorMessage = error.localizedDescription
      }
    }

    public func cancel() {
      clear()
    }

    public func closePresentation() {
      if hasReview, !isRunning, model.proposal?.comments.isEmpty != false { clear() }
    }

    public func clear() {
      generationID = nil
      task?.cancel()
      task = nil
      model.cancel()
      hasReview = false
      isPreparing = false
      // A cancelled backend can finish late. It must never repopulate this document's Review.
      model = makeModel()
    }
  }
#endif
