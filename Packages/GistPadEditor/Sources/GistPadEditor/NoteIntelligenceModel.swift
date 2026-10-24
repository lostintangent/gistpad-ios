#if canImport(UIKit)
  import GistPadIntelligence
  import Observation
  import UIKit

  @MainActor
  @Observable
  final class NoteIntelligenceModel {
    let session: DocumentSession
    var action = NoteIntelligenceAction.ask
    var askPrompt = ""
    var editPrompt = ""
    var isRunning = false
    var isCancelling = false
    var available = false
    var availabilityReason: String?
    var errorMessage: String?
    var notice: String?
    var progress: NoteIntelligenceProgress?
    var answerParts: [NoteAnswerPart] = []
    var proposal: NoteProposal?
    var appliedEdit: NoteProposal?
    var appliedCount = 0
    var applyFeedback = 0
    private(set) var snapshot: NoteSnapshot?
    private let backend: any NoteModelBackend
    private let engine: NoteIntelligenceEngine
    private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(
      session: DocumentSession, backend: any NoteModelBackend,
      isCurrent: @escaping @MainActor () -> Bool
    ) {
      self.session = session
      self.backend = backend
      engine = NoteIntelligenceEngine(backend: backend)
      self.isCurrent = isCurrent
    }

    var prompt: String {
      get { action == .edit ? editPrompt : askPrompt }
      set {
        if action == .edit { editPrompt = newValue } else { askPrompt = newValue }
      }
    }

    var isStale: Bool {
      guard isCurrent() else { return true }
      guard let snapshot else { return false }
      return session.viewIdentity != snapshot.sessionID || session.documentID != snapshot.documentID
        || session.generation != snapshot.generation
        || !session.text.utf8.elementsEqual(snapshot.source.utf8)
    }

    var canGenerate: Bool {
      available && !isRunning && isCurrent()
        && (action == .review || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (action != .edit || session.textView.isEditable)
    }

    var canApply: Bool {
      !isRunning && !isStale && session.canFormat
    }

    func checkAvailability() async {
      do {
        _ = try await backend.modelInfo()
        available = true
        availabilityReason = nil
      } catch {
        available = false
        availabilityReason = error.localizedDescription
      }
    }

    func clearResults() {
      errorMessage = nil
      notice = nil
      progress = nil
      answerParts = []
      proposal = nil
      appliedEdit = nil
      appliedCount = 0
      snapshot = nil
    }

    func generate() {
      guard canGenerate else { return }
      clearResults()
      isRunning = true
      isCancelling = false
      let selectedAction = action
      let instruction = selectedAction == .review ? "" : prompt
      task = Task { [weak self] in
        guard let self else { return }
        defer {
          self.isRunning = false
          self.isCancelling = false
          self.progress = nil
          self.task = nil
        }
        do {
          guard self.isCurrent() else { throw NoteIntelligenceError.staleSnapshot }
          let snapshot = try self.session.intelligenceSnapshot()
          self.snapshot = snapshot
          let request = NoteIntelligenceRequest(
            snapshot: snapshot, action: selectedAction, instruction: instruction)
          if selectedAction == .ask {
            let answer = try await self.engine.ask(
              request, progress: { self.progress = $0 }, onUpdate: { self.answerParts = $0 })
            self.answerParts = answer.parts
          } else {
            self.proposal = try await self.engine.propose(request, progress: { self.progress = $0 })
          }
        } catch is CancellationError {
          self.answerParts = []
          self.proposal = nil
          self.notice = String(localized: "Cancelled. Your note is unchanged.", bundle: .module)
        } catch {
          self.answerParts = []
          self.proposal = nil
          self.errorMessage = error.localizedDescription
        }
      }
    }

    func cancel() {
      guard isRunning else { return }
      isCancelling = true
      task?.cancel()
    }

    func apply(commentID: UUID? = nil) {
      guard let proposal else {
        errorMessage = NoteIntelligenceError.noApplicableChanges.localizedDescription
        return
      }
      do {
        guard !isRunning, !isStale else { throw NoteIntelligenceError.staleSnapshot }
        let count = proposal.comments.filter {
          $0.canApply && (commentID == nil || $0.id == commentID)
        }.count
        let remaining = try session.applyIntelligenceProposal(proposal, commentID: commentID)
        if action == .edit { appliedEdit = proposal }
        self.proposal = remaining
        snapshot = remaining.snapshot
        appliedCount += count
        applyFeedback &+= 1
        errorMessage = nil
        notice = String(
          localized: "Applied. The editor's Undo restores your text.", bundle: .module)
      } catch {
        errorMessage = error.localizedDescription
      }
    }

    func canReveal(_ range: NSRange) -> Bool {
      guard !isStale, let snapshot else { return false }
      return Range(range, in: snapshot.source) != nil
    }
  }
#endif
