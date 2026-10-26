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

    var isRunning: Bool { isPreparing || model.isRunning }
    public var isStale: Bool { model.isStale }
    var canApply: Bool { hasReview && !isPreparing && model.canApply }
    var canDismiss: Bool { hasReview && !isRunning }

    func generate() {
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

    func apply(commentID: UUID) {
      model.apply(commentID: commentID)
      if model.proposal?.comments.isEmpty == true { hasReview = false }
    }

    func dismiss(commentID: UUID) {
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

    func closePresentation() {
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
