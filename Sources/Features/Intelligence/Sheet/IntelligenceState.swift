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
        var isApplied = false
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
                && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var canApply: Bool {
            !isRunning && !isApplied && !isStale && editor.canFormat && proposal?.canApply == true
        }

        func clearResults() {
            errorMessage = nil
            notice = nil
            progress = nil
            answer = nil
            proposal = nil
            isApplied = false
            document = nil
        }

        func generate() {
            guard canGenerate else { return }
            clearResults()
            let selectedAction = action
            let instruction = prompt
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

        func apply() {
            guard let proposal, canApply else { return }
            do {
                try editor.apply(proposal)
                isApplied = true
                document = editor.document
                errorMessage = nil
                notice = String(
                    localized: "Applied. Undo restores your text.", bundle: .module)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
#endif
