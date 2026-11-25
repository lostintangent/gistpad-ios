#if canImport(UIKit)
    import Editor
    import SwiftUI
    import UIKit

    public struct IntelligenceSheet: View {
        private let title: String
        private let revealSource: @MainActor (NSRange) -> Void
        @State private var state: IntelligenceState
        @State private var detent = PresentationDetent.medium
        @Environment(\.dismiss) private var dismiss
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @FocusState private var promptFocused: Bool

        public init(
            editor: MarkdownEditor, title: String, revealSource: @escaping @MainActor (NSRange) -> Void
        ) {
            self.title = title
            self.revealSource = revealSource
            _state = State(initialValue: IntelligenceState(editor: editor))
        }

        public var body: some View {
            @Bindable var state = state
            NavigationStack {
                Form {
                    Section {
                        Picker(String(localized: "Action", bundle: .module), selection: $state.action) {
                            ForEach(IntelligenceAction.allCases, id: \.self) { action in
                                Text(action.title).tag(action)
                                    .disabled(action == .edit && !state.editor.isEditable)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(state.isRunning)
                        .accessibilityIdentifier("intelligence-actions")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    request
                    if let reason = state.availabilityReason {
                        Section { Label(reason, systemImage: "apple.intelligence") }
                    }
                    if let error = state.errorMessage {
                        Section { Label(error, systemImage: "exclamationmark.circle") }
                    }
                    if state.isRunning {
                        Section {
                            LabeledContent(progressLabel) { ProgressView() }
                                .accessibilityIdentifier("intelligence-progress")
                        }
                    }
                    if state.isStale {
                        Section {
                            Label(
                                IntelligenceError.noteChanged.localizedDescription,
                                systemImage: "arrow.clockwise")
                        }
                    }
                    answer
                    if let proposal = state.appliedEdit ?? state.proposal { changes(proposal) }
                    if let notice = state.notice {
                        Section {
                            Label(
                                notice, systemImage: state.appliedCount > 0 ? "checkmark.circle" : "info.circle")
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            state.cancel()
                            dismiss()
                        }
                        .accessibilityIdentifier("intelligence-close")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if state.isRunning {
                            Button(String(localized: "Stop", bundle: .module), systemImage: "stop.fill") {
                                state.cancel()
                            }
                            .disabled(state.isCancelling)
                            .accessibilityIdentifier("intelligence-cancel")
                        } else {
                            Button(state.action.title, role: .confirm) {
                                promptFocused = false
                                state.generate()
                            }
                            .disabled(!state.canGenerate)
                            .accessibilityIdentifier("intelligence-generate")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .sensoryFeedback(.success, trigger: state.appliedCount) { old, new in new > old }
            .onChange(of: state.action) { state.clearResults() }
            .onChange(
                of: state.isRunning || state.proposal != nil || dynamicTypeSize.isAccessibilitySize,
                initial: true
            ) { _, expands in
                if expands { detent = .large }
            }
            .onDisappear { state.cancel() }
            .accessibilityIdentifier("note-intelligence-sheet")
        }

        @ViewBuilder
        private var request: some View {
            @Bindable var state = state
            Section {
                switch state.action {
                case .review:
                    if !state.hasResults {
                        Text("Find errors and unclear wording.", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                case .ask, .edit:
                    TextField(
                        state.action == .ask
                            ? String(localized: "Ask about this file", bundle: .module)
                            : String(localized: "What would you like to change?", bundle: .module),
                        text: $state.prompt, axis: .vertical
                    )
                    .lineLimit(1...5)
                    .focused($promptFocused)
                    .disabled(state.isRunning)
                    .accessibilityIdentifier("intelligence-prompt")
                }
            } footer: {
                if !state.editor.isEditable {
                    Text(
                        "This gist is read-only. You can ask and review, but not apply changes.",
                        bundle: .module)
                }
            }
        }

        private var progressLabel: String {
            if state.isCancelling { return String(localized: "Stopping…", bundle: .module) }
            guard let progress = state.progress else {
                return String(localized: "Preparing this file…", bundle: .module)
            }
            switch progress {
            case .answering:
                return String(localized: "Answering…", bundle: .module)
            case .combining(let current, let total):
                return String(localized: "Combining passages \(current) of \(total)…", bundle: .module)
            case .reading(let current, let total):
                return String(localized: "Reading part \(current) of \(total)…", bundle: .module)
            case .editing(let current, let total):
                return String(localized: "Editing part \(current) of \(total)…", bundle: .module)
            case .reviewing(let current, let total):
                return String(localized: "Reviewing part \(current) of \(total)…", bundle: .module)
            }
        }

        @ViewBuilder
        private var answer: some View {
            if let answer = state.answer {
                if !answer.prose.isEmpty {
                    Section { Text(answer.prose).textSelection(.enabled) }
                }
                ForEach(answer.citations.enumerated(), id: \.offset) { _, citation in
                    Section {
                        Text(citation.text).textSelection(.enabled)
                        if citation.ranges.count == 1, let range = citation.ranges.first {
                            Button(
                                String(localized: "Show in File", bundle: .module), systemImage: "text.viewfinder"
                            ) { reveal(range) }
                            .disabled(state.isStale)
                        } else if citation.ranges.count > 1 {
                            Menu(
                                String(localized: "Show in File", bundle: .module), systemImage: "text.viewfinder"
                            ) {
                                ForEach(citation.ranges.enumerated(), id: \.offset) { index, range in
                                    Button(String(localized: "Match \(index + 1)", bundle: .module)) {
                                        reveal(range)
                                    }
                                    .disabled(state.isStale)
                                }
                            }
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private func changes(_ proposal: Proposal) -> some View {
            if proposal.omittedCount > 0 {
                Section {
                    Label(
                        String(
                            localized:
                                "\(proposal.omittedCount) changes couldn’t be found in your file and won’t be applied.",
                            bundle: .module),
                        systemImage: "exclamationmark.circle")
                }
            }
            if proposal.changes.isEmpty, state.appliedCount == 0 {
                Section {
                    Text(
                        state.action == .edit
                            ? String(localized: "No changes needed.", bundle: .module)
                            : String(localized: "No suggestions.", bundle: .module)
                    )
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(proposal.changes.enumerated(), id: \.element.id) { index, change in
                Section {
                    self.change(change)
                } header: {
                    if index == 0, state.action == .review {
                        Text(
                            proposal.changes.count == 1
                                ? String(localized: "1 suggestion", bundle: .module)
                                : String(localized: "\(proposal.changes.count) suggestions", bundle: .module))
                    }
                }
            }
            if state.action == .edit, state.appliedEdit == nil, proposal.canApply {
                Section {
                    Button(String(localized: "Apply Edit", bundle: .module), systemImage: "checkmark") {
                        state.apply()
                    }
                    .disabled(!state.canApply)
                    .accessibilityIdentifier("intelligence-apply")
                }
            }
        }

        private static func attributed(_ runs: [TextDiff.Run]) -> AttributedString {
            var result = AttributedString()
            for run in runs {
                var text = AttributedString(run.text)
                switch run.kind {
                case .unchanged:
                    text.foregroundColor = .primary
                case .removed:
                    text.foregroundColor = .secondary
                    text.strikethroughStyle = Text.LineStyle(pattern: .solid)
                case .added:
                    text.foregroundColor = .primary
                    text.font = .body.weight(.semibold)
                    text.underlineStyle = Text.LineStyle(pattern: .solid)
                }
                result += text
            }
            return result
        }

        @ViewBuilder
        private func change(_ change: Proposal.Change) -> some View {
            // A whole line's change carries its line break, which shows as a blank line.
            let quote = change.quote.trimmingCharacters(in: .newlines)
            let comparison = change.replacement.map {
                TextDiff(before: quote, after: $0.trimmingCharacters(in: .newlines))
            }
            // A rewrite's Before and After say what changes, so only task changes carry a headline.
            if !change.reason.isEmpty { Text(change.reason).font(.headline) }
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    change.range == nil
                        ? String(localized: "Unverified Quote", bundle: .module)
                        : String(localized: "Before", bundle: .module)
                )
                .font(.caption).fontWeight(.semibold)
                if change.quote.isEmpty {
                    Text("Empty file", bundle: .module).foregroundStyle(.secondary)
                } else if let comparison {
                    Text(Self.attributed(comparison.before)).textSelection(.enabled)
                } else {
                    Text(quote).textSelection(.enabled)
                }
            }
            if let replacement = change.replacement, let comparison {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After", bundle: .module).font(.caption).fontWeight(.semibold)
                    if replacement.isEmpty {
                        Text("Remove this text", bundle: .module).foregroundStyle(.secondary)
                    } else {
                        Text(Self.attributed(comparison.after)).textSelection(.enabled)
                    }
                }
            }
            if change.range == nil {
                Label(String(localized: "Can’t Apply", bundle: .module), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if state.action == .review {
                if change.canApply {
                    Button(String(localized: "Apply", bundle: .module)) {
                        state.apply(changeID: change.id)
                    }
                    .disabled(!state.canApply)
                }
                Button(String(localized: "Dismiss", bundle: .module)) {
                    state.dismiss(changeID: change.id)
                }
                .disabled(state.isRunning)
            }
        }

        private func reveal(_ range: NSRange) {
            revealSource(range)
            dismiss()
        }
    }
#endif
