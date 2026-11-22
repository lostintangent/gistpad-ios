#if canImport(UIKit)
  import Editor
  import Observation
  import OSLog
  import UIKit

  @MainActor
  @Observable
  final class IntelligenceState {
    let editor: Editor
    var action = IntelligenceAction.ask
    var askPrompt = ""
    var editPrompt = ""
    var isCancelling = false
    var errorMessage: String?
    var notice: String?
    var progress: IntelligenceEngine.Progress?
    var answerParts: [AnswerPart] = []
    var proposal: Proposal?
    var appliedEdit: Proposal?
    var appliedCount = 0
    private(set) var snapshot: FileSnapshot?
    private let engine: IntelligenceEngine
    private(set) var task: Task<Void, Never>?

    init(editor: Editor, backend: any IntelligenceModel = OnDeviceModel()) {
      self.editor = editor
      engine = IntelligenceEngine(backend: backend)
    }

    var prompt: String {
      get { action == .edit ? editPrompt : askPrompt }
      set {
        if action == .edit { editPrompt = newValue } else { askPrompt = newValue }
      }
    }

    var isRunning: Bool { task != nil }

    var isStale: Bool {
      guard let snapshot else { return false }
      return editor.id != snapshot.sessionID || editor.generation != snapshot.generation
        || !editor.text.utf8.elementsEqual(snapshot.source.utf8)
    }

    var availabilityReason: String? { engine.backend.unavailableReason }

    var canGenerate: Bool {
      availabilityReason == nil && !isRunning
        && (action == .review || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (action != .edit || editor.isEditable)
    }

    var canApply: Bool {
      !isRunning && !isStale && editor.canFormat && proposal?.canApply == true
    }

    var hasResults: Bool {
      !answerParts.isEmpty || proposal != nil || appliedEdit != nil
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
      let selectedAction = action
      let instruction = selectedAction == .review ? "" : prompt
      let requestID = UUID()
      logger.notice(
        "request=\(requestID.uuidString, privacy: .public) action=\(selectedAction.rawValue, privacy: .public) state=started sourceUTF16=\(self.editor.text.utf16.count)"
      )
      task = Task { [weak self] in
        guard let self else { return }
        defer {
          self.isCancelling = false
          self.progress = nil
          self.task = nil
        }
        do {
          let snapshot = self.editor.snapshot()
          self.snapshot = snapshot
          let request = IntelligenceRequest(
            snapshot: snapshot, instruction: instruction, id: requestID)
          switch selectedAction {
          case .ask:
            self.answerParts = try await self.engine.ask(
              request, progress: { self.progress = $0 },
              onPartialAnswer: { text in
                self.answerParts = text.isEmpty ? [] : [.prose(text)]
              })
          case .edit:
            self.proposal = try await self.engine.edit(request, progress: { self.progress = $0 })
          case .review:
            self.proposal = try await self.engine.review(request, progress: { self.progress = $0 })
          }
        } catch is CancellationError {
          if selectedAction == .ask { self.answerParts = [] }
          self.notice = String(localized: "Cancelled. Your file is unchanged.", bundle: .module)
        } catch {
          if selectedAction == .ask { self.answerParts = [] }
          self.errorMessage = error.localizedDescription
          let failure =
            (error as? IntelligenceError).map { String(describing: $0) }
            ?? String(reflecting: type(of: error))
          logger.error(
            "request=\(requestID.uuidString, privacy: .public) failure=\(failure, privacy: .public)")
        }
      }
    }

    func cancel() {
      guard isRunning else { return }
      isCancelling = true
      task?.cancel()
    }

    func apply(changeID: UUID? = nil) {
      guard let proposal, canApply else { return }
      do {
        let count = proposal.changes.filter {
          $0.canApply && (changeID == nil || $0.id == changeID)
        }.count
        let remaining = try editor.apply(proposal, changeID: changeID)
        if action == .edit { appliedEdit = proposal }
        self.proposal = remaining
        snapshot = remaining.snapshot
        appliedCount += count
        errorMessage = nil
        notice = String(
          localized: "Applied. The editor's Undo restores your text.", bundle: .module)
      } catch {
        errorMessage = error.localizedDescription
      }
    }

    func dismiss(changeID: UUID) {
      proposal = proposal?.dismissing(changeID: changeID)
      errorMessage = nil
    }
  }
#endif
