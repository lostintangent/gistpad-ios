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
    var isRunning = false
    var isCancelling = false
    var available = false
    var availabilityReason: String?
    var errorMessage: String?
    var notice: String?
    var progress: IntelligenceProgress?
    var answerParts: [AnswerPart] = []
    var review: Review?
    var appliedEdit: Review?
    var appliedCount = 0
    var applyFeedback = 0
    private(set) var snapshot: FileSnapshot?
    private let engine: Intelligence
    private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(editor: Editor, backend: any IntelligenceModel = OnDeviceModel()) {
      self.editor = editor
      engine = Intelligence(backend: backend)
    }

    var prompt: String {
      get { action == .edit ? editPrompt : askPrompt }
      set {
        if action == .edit { editPrompt = newValue } else { askPrompt = newValue }
      }
    }

    var isStale: Bool {
      guard let snapshot else { return false }
      return editor.id != snapshot.sessionID || editor.fileID != snapshot.fileID
        || editor.generation != snapshot.generation
        || !editor.text.utf8.elementsEqual(snapshot.source.utf8)
    }

    var canGenerate: Bool {
      available && !isRunning
        && (action == .review || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (action != .edit || editor.textView.isEditable)
    }

    var canApply: Bool {
      !isRunning && !isStale && editor.canFormat && review?.canApply == true
    }

    var hasResults: Bool {
      !answerParts.isEmpty || review != nil || appliedEdit != nil
    }

    func checkAvailability() async {
      do {
        _ = try await engine.backend.modelInfo()
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
      review = nil
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
      let requestID = UUID()
      logger.notice(
        "request=\(requestID.uuidString, privacy: .public) action=\(selectedAction.rawValue, privacy: .public) state=started sourceUTF16=\(self.editor.text.utf16.count)"
      )
      task = Task { [weak self] in
        guard let self else { return }
        defer {
          self.isRunning = false
          self.isCancelling = false
          self.progress = nil
          self.task = nil
        }
        do {
          let snapshot = try self.editor.snapshot()
          self.snapshot = snapshot
          let request = IntelligenceRequest(
            snapshot: snapshot, action: selectedAction, instruction: instruction, id: requestID)
          switch selectedAction {
          case .ask:
            self.answerParts = try await self.engine.ask(
              request, progress: { self.progress = $0 },
              onPartialAnswer: { text in
                self.answerParts = text.isEmpty ? [] : [.prose(text)]
              })
          case .edit:
            self.review = try await self.engine.edit(request, progress: { self.progress = $0 })
          case .review:
            self.review = try await self.engine.review(request, progress: { self.progress = $0 })
          }
        } catch is CancellationError {
          if selectedAction == .ask { self.answerParts = [] }
          self.notice = String(localized: "Cancelled. Your file is unchanged.", bundle: .module)
        } catch {
          if selectedAction == .ask { self.answerParts = [] }
          self.errorMessage = Self.message(for: error)
          let failure =
            (error as? IntelligenceError).map { String(describing: $0) }
            ?? String(reflecting: type(of: error))
          self.logger.error(
            "request=\(requestID.uuidString, privacy: .public) failure=\(failure, privacy: .public)")
        }
      }
    }

    private static func message(for error: any Error) -> String {
      let message = error.localizedDescription
      return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? String(
          localized:
            "Apple Intelligence couldn't complete this request. Try again. Your file is unchanged.",
          bundle: .module) : message
    }

    func cancel() {
      guard isRunning else { return }
      isCancelling = true
      task?.cancel()
    }

    func apply(commentID: UUID? = nil) {
      guard let review else { return }
      do {
        guard !isRunning, !isStale else { throw IntelligenceError.staleSnapshot }
        let count = review.comments.filter {
          $0.canApply && (commentID == nil || $0.id == commentID)
        }.count
        let remaining = try editor.apply(review, commentID: commentID)
        if action == .edit { appliedEdit = review }
        self.review = remaining
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

    func dismiss(commentID: UUID) {
      guard let review else { return }
      do {
        self.review = try review.dismissing(commentID: commentID)
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    }

    func canReveal(_ range: NSRange) -> Bool {
      guard !isStale, let snapshot else { return false }
      return !isHiddenFrontMatterReference(range) && Range(range, in: snapshot.source) != nil
    }

    func isHiddenFrontMatterReference(_ range: NSRange) -> Bool {
      range.location < editor.contentStart
    }
  }
#endif
