#if canImport(UIKit)
    import Editor
    import Markdown
    import Observation
    import OSLog
    import UIKit

    @Observable
    final class IntelligenceState {
        let editor: MarkdownEditor
        private let model: any IntelligenceModel
        var action = IntelligenceAction.ask
        var askPrompt = ""
        var editPrompt = ""
        var isCancelling = false
        var errorMessage: String?
        var notice: String?
        var progress: IntelligenceRequest.Progress?
        var answer: Answer?
        var proposal: Proposal?
        var appliedEdit: Proposal?
        var appliedCount = 0
        private(set) var document: MarkdownDocument?
        private(set) var task: Task<Void, Never>?

        init(editor: MarkdownEditor, model: any IntelligenceModel = OnDeviceModel()) {
            self.editor = editor
            self.model = model
        }

        var prompt: String {
            get { action == .edit ? editPrompt : askPrompt }
            set {
                if action == .edit { editPrompt = newValue } else { askPrompt = newValue }
            }
        }

        var isRunning: Bool { task != nil }

        var isStale: Bool { document.map { $0 != editor.document } ?? false }

        var availabilityReason: String? { model.unavailableReason }

        var canGenerate: Bool {
            availabilityReason == nil && !isRunning
                && (action == .review || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && (action != .edit || editor.isEditable)
        }

        var canApply: Bool {
            !isRunning && !isStale && editor.canFormat && proposal?.canApply == true
        }

        var hasResults: Bool {
            answer != nil || proposal != nil || appliedEdit != nil
        }

        func clearResults() {
            errorMessage = nil
            notice = nil
            progress = nil
            answer = nil
            proposal = nil
            appliedEdit = nil
            appliedCount = 0
            document = nil
        }

        func generate() {
            guard canGenerate else { return }
            clearResults()
            let selectedAction = action
            let instruction = selectedAction == .review ? "" : prompt
            let requestID = UUID()
            logger.notice(
                "request=\(requestID.uuidString, privacy: .public) action=\(selectedAction.rawValue, privacy: .public) state=started sourceUTF16=\(self.editor.document.text.utf16.count)"
            )
            task = Task {
                defer {
                    self.isCancelling = false
                    self.progress = nil
                    self.task = nil
                }
                do {
                    let document = self.editor.document
                    self.document = document
                    let request = IntelligenceRequest(
                        document: document, instruction: instruction, id: requestID)
                    switch selectedAction {
                    case .ask:
                        self.answer = try await self.model.ask(
                            request, progress: { self.progress = $0 },
                            onPartialAnswer: { text in
                                self.answer = text.isEmpty ? nil : Answer(prose: text)
                            })
                    case .edit:
                        self.proposal = try await self.model.edit(request, progress: { self.progress = $0 })
                    case .review:
                        self.proposal = try await self.model.review(request, progress: { self.progress = $0 })
                    }
                } catch is CancellationError {
                    if selectedAction == .ask { self.answer = nil }
                    self.notice = String(localized: "Cancelled. Your file is unchanged.", bundle: .module)
                } catch {
                    if selectedAction == .ask { self.answer = nil }
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
                let remaining = try editor.apply(proposal, changeID: changeID)
                if action == .edit { appliedEdit = proposal }
                self.proposal = remaining
                document = remaining.document
                appliedCount += proposal.changes.count - remaining.changes.count
                errorMessage = nil
                notice = String(
                    localized: "Applied. The editor’s Undo restores your text.", bundle: .module)
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
