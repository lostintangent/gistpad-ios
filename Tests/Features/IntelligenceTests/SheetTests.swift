#if canImport(UIKit)
    import Editor
    import Foundation
    import Testing

    @testable import Intelligence

    @Suite(.timeLimit(.minutes(1)))
    struct SheetTests {
        private let source = FixtureLanguageModel.source

        @Test func nothingChangesUntilApply() async {
            let editor = MarkdownEditor(text: source)
            var changes = 0
            editor.onEdit = { _, _ in changes += 1 }
            let state = IntelligenceState(editor: editor, backend: FixtureLanguageModel())
            state.action = .edit
            state.editPrompt = "Fix the typo and the time"
            state.generate()
            await state.task?.value
            #expect(state.canApply)
            #expect(changes == 0)
            #expect(editor.document.text == source)

            state.apply()
            #expect(state.errorMessage == nil)
            #expect(
                editor.document.text
                    == source.replacingOccurrences(of: "teh", with: "the")
                    .replacingOccurrences(of: "before the cafe", with: "after the cafe"))
            #expect(editor.generation == 1)
            #expect(changes == 1)
            #expect(state.appliedCount == 2)
        }

        enum AskFailure: Sendable {
            case unavailable, error(IntelligenceError), answer(ModelAnswer)
        }

        @Test(arguments: [
            AskFailure.unavailable, .error(.refused), .answer(ModelAnswer(prose: " \r\n\t")),
        ])
        func everyFailedAskShowsAReasonAndKeepsTheRequestAndFile(failure: AskFailure) async {
            let editor = MarkdownEditor(text: source)
            var changes = 0
            editor.onEdit = { _, _ in changes += 1 }
            let fixture = FixtureLanguageModel()
            switch failure {
            case .unavailable: fixture.unavailableReason = "Apple Intelligence is turned off."
            case .error(let error): fixture.failure = error
            case .answer(let answer): fixture.answer = answer
            }
            let state = IntelligenceState(editor: editor, backend: fixture)
            state.askPrompt = "When do I leave?"
            state.generate()
            await state.task?.value
            let reason = state.errorMessage ?? state.availabilityReason ?? ""
            #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!state.isRunning)
            #expect(state.answerParts.isEmpty)
            #expect(state.askPrompt == "When do I leave?")
            #expect(editor.document.text == source)
            #expect(editor.generation == 0)
            #expect(changes == 0)
        }

        @Test func cancelKeepsTheRequestAndTheFile() async {
            let editor = MarkdownEditor(text: source)
            let fixture = FixtureLanguageModel()
            fixture.isHeld = true
            let state = IntelligenceState(editor: editor, backend: fixture)
            state.askPrompt = "When do I leave?"
            state.generate()
            for await count in Observations({ fixture.passes.count }) where count > 0 { break }
            #expect(state.isRunning)
            state.cancel()
            await state.task?.value
            #expect(!state.isRunning)
            #expect(state.answerParts.isEmpty)
            #expect(state.notice != nil)
            #expect(state.errorMessage == nil)
            #expect(state.askPrompt == "When do I leave?")
            #expect(editor.document.text == source)
            #expect(editor.generation == 0)
        }

        @Test func aReadOnlyFileAllowsAskAndReviewButNotEditOrApply() async {
            let editor = MarkdownEditor(text: source)
            editor.isEditable = false
            let state = IntelligenceState(editor: editor, backend: FixtureLanguageModel())
            state.askPrompt = "When do I leave?"
            #expect(state.canGenerate)
            state.action = .edit
            state.editPrompt = "Fix the typo"
            #expect(!state.canGenerate)
            state.action = .review
            #expect(state.canGenerate)
            state.generate()
            await state.task?.value
            #expect(state.proposal?.changes.count == 2)
            #expect(!state.canApply)
            state.apply()
            #expect(editor.document.text == source)
            #expect(editor.generation == 0)
        }

        @Test(arguments: [false, true])
        func citationsOnlyLinkToVisibleBodyEvenWhenMetadataRepeatsTheQuote(shown: Bool) async throws {
            let prefix = "---\nkey: e\u{301} 👩🏽‍💻\n---\n\n"
            let text = prefix + "# Content\n\nA retained thought about e\u{301} 👩🏽‍💻."
            let editor = MarkdownEditor(text: text, generation: 8, showsFrontMatter: shown)
            let fixture = FixtureLanguageModel()
            fixture.answer = ModelAnswer(
                prose: "You retained this thought.", quotes: ["e\u{301} 👩🏽‍💻"])
            let state = IntelligenceState(editor: editor, backend: fixture)
            state.askPrompt = "What thought did I retain?"
            state.generate()
            await state.task?.value
            guard case .quotation(_, let ranges) = try #require(state.answerParts.last) else {
                Issue.record("Expected a verified quotation")
                return
            }
            let reference = try #require(ranges.first)
            #expect(ranges.count == 1)
            #expect(reference.location >= prefix.utf16.count)
            #expect(!state.isStale)
            editor.setShowsFrontMatter(!shown)
            #expect(!state.isStale)
            editor.setShowsFrontMatter(shown)
            #expect(editor.document.text.utf8.elementsEqual(text.utf8))
            #expect(editor.generation == 8)
        }
    }
#endif
