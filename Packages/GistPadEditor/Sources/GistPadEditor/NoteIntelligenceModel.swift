#if canImport(UIKit)
  import GistPadIntelligence
  import Observation
  import OSLog
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
    private(set) var submittedPrompt: String?
    private let backend: any NoteModelBackend
    private let engine: NoteIntelligenceEngine
    private let isCurrent: @MainActor () -> Bool
    private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")
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

    func modelFactory(action: NoteIntelligenceAction) -> @MainActor () -> NoteIntelligenceModel {
      let session = session
      let backend = backend
      let isCurrent = isCurrent
      return {
        let model = NoteIntelligenceModel(
          session: session, backend: backend, isCurrent: isCurrent)
        model.action = action
        return model
      }
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
      !isRunning && !isStale && session.canFormat && proposal?.canApply == true
    }

    var hasResults: Bool {
      !answerParts.isEmpty || proposal != nil || appliedEdit != nil
    }

    func checkAvailability() async {
      do {
        _ = try await backend.modelInfo()
        available = true
        availabilityReason = nil
      } catch {
        available = false
        availabilityReason = Self.message(for: error)
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
      submittedPrompt = nil
    }

    func generate() {
      guard canGenerate else { return }
      clearResults()
      isRunning = true
      isCancelling = false
      let selectedAction = action
      let instruction = selectedAction == .review ? "" : prompt
      submittedPrompt = selectedAction == .review ? nil : instruction
      let requestID = UUID()
      logger.notice(
        "request=\(requestID.uuidString, privacy: .public) action=\(selectedAction.rawValue, privacy: .public) state=started sourceUTF16=\(self.session.text.utf16.count)"
      )
      task = Task { [weak self] in
        guard let self else { return }
        var failureCode: String?
        var failureType: String?
        self.backend.beginAttempt(id: requestID, action: selectedAction)
        defer {
          if selectedAction == .ask, self.answerParts.isEmpty,
            self.errorMessage == nil, self.notice == nil
          {
            self.errorMessage = NoteIntelligenceError.emptyAnswer.localizedDescription
            failureCode = NoteIntelligenceError.emptyAnswer.diagnosticCode
            failureType = String(reflecting: NoteIntelligenceError.self)
          }
          self.isRunning = false
          self.isCancelling = false
          self.progress = nil
          self.task = nil
          self.backend.finishAttempt(
            id: requestID, errorCode: failureCode, errorType: failureType)
          self.logger.notice(
            "request=\(requestID.uuidString, privacy: .public) state=finished answerParts=\(self.answerParts.count) changes=\(self.proposal?.comments.count ?? 0) hasError=\(self.errorMessage != nil) cancelled=\(Task.isCancelled)"
          )
        }
        do {
          guard self.isCurrent() else { throw NoteIntelligenceError.staleSnapshot }
          let snapshot = try self.session.intelligenceSnapshot()
          self.snapshot = snapshot
          let request = NoteIntelligenceRequest(
            snapshot: snapshot, action: selectedAction, instruction: instruction, id: requestID)
          if selectedAction == .ask {
            let answer = try await self.engine.ask(
              request, progress: { self.progress = $0 }, onUpdate: { self.answerParts = $0 })
            self.answerParts = answer.parts
          } else {
            self.proposal = try await self.engine.propose(request, progress: { self.progress = $0 })
          }
        } catch is CancellationError {
          failureCode = "cancelled"
          failureType = String(reflecting: CancellationError.self)
          self.answerParts = []
          self.proposal = nil
          self.notice = String(localized: "Cancelled. Your note is unchanged.", bundle: .module)
        } catch {
          self.answerParts = []
          self.proposal = nil
          self.errorMessage = Self.message(for: error)
          let code = (error as? NoteIntelligenceError)?.diagnosticCode ?? "unexpected"
          failureCode = code
          failureType = String(reflecting: type(of: error))
          self.logger.error(
            "request=\(requestID.uuidString, privacy: .public) failure=\(code, privacy: .public)")
        }
      }
    }

    private static func message(for error: any Error) -> String {
      let message = error.localizedDescription
      return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? String(
          localized:
            "Apple Intelligence couldn't complete this request. Try again. Your note is unchanged.",
          bundle: .module) : message
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
      return !isHiddenFrontMatterReference(range) && Range(range, in: snapshot.source) != nil
    }

    func isHiddenFrontMatterReference(_ range: NSRange) -> Bool {
      range.location < session.contentStart
    }
  }
#endif
