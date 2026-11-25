#if canImport(UIKit)
    import Editor
    import SwiftUI
    import UIKit

    public struct IntelligenceSheet: View {
        private let title: String
        private let canEdit: Bool
        private let revealSource: @MainActor (NSRange) -> Void
        @State private var state: IntelligenceState
        @State private var detent = PresentationDetent.medium
        @Environment(\.dismiss) private var dismiss
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @FocusState private var promptFocused: Bool

        /// `canEdit` offers Edit beside Ask. Pass whether the file is yours as the sheet opens, not
        /// whether the editor is editable right now, which a committing change briefly turns off.
        public init(
            editor: MarkdownEditor, title: String, canEdit: Bool,
            revealSource: @escaping @MainActor (NSRange) -> Void
        ) {
            self.title = title
            self.canEdit = canEdit
            self.revealSource = revealSource
            _state = State(initialValue: IntelligenceState(editor: editor))
        }

        public var body: some View {
            @Bindable var state = state
            NavigationStack {
                Form {
                    if canEdit {
                        Section {
                            Picker(String(localized: "Action", bundle: .module), selection: $state.action) {
                                ForEach(IntelligenceAction.allCases, id: \.self) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(state.isRunning)
                            .accessibilityIdentifier("intelligence-actions")
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
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
                    if let proposal = state.proposal { changes(proposal) }
                    if let notice = state.notice {
                        Section {
                            Label(notice, systemImage: state.isApplied ? "checkmark.circle" : "info.circle")
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
            .sensoryFeedback(.success, trigger: state.isApplied) { _, isApplied in isApplied }
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
                        Text(citation.passage).lineLimit(3).textSelection(.enabled)
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
            if proposal.changes.isEmpty {
                Section {
                    Text("No changes needed.", bundle: .module).foregroundStyle(.secondary)
                }
            }
            ForEach(proposal.changes) { change in
                Section { self.change(change) }
            }
            if !state.isApplied, proposal.canApply {
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
            let comparison = TextDiff(
                before: quote, after: change.replacement.trimmingCharacters(in: .newlines))
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
                } else {
                    Text(Self.attributed(comparison.before)).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("After", bundle: .module).font(.caption).fontWeight(.semibold)
                if change.replacement.isEmpty {
                    Text("Remove this text", bundle: .module).foregroundStyle(.secondary)
                } else {
                    Text(Self.attributed(comparison.after)).textSelection(.enabled)
                }
            }
            if change.range == nil {
                Label(String(localized: "Can’t Apply", bundle: .module), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }

        private func reveal(_ range: NSRange) {
            revealSource(range)
            dismiss()
        }
    }
#endif
