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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var promptFocused: Bool

    public init(
      editor: Editor, title: String, revealSource: @escaping @MainActor (NSRange) -> Void
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
                  .disabled(action == .edit && !state.editor.textView.isEditable)
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
                IntelligenceError.staleSnapshot.localizedDescription,
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
      .task {
        if dynamicTypeSize.isAccessibilitySize { detent = .large }
        await state.checkAvailability()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await state.checkAvailability() } }
      }
      .onChange(of: state.action) {
        state.clearResults()
        Task { await state.checkAvailability() }
      }
      .onChange(of: state.isRunning || state.proposal != nil || dynamicTypeSize.isAccessibilitySize)
      { _, expands in
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
        if !state.editor.textView.isEditable {
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
      switch progress.phase {
      case .answering:
        return String(localized: "Answering…", bundle: .module)
      case .combining:
        return String(
          localized: "Combining passages \(progress.current) of \(progress.total)…", bundle: .module
        )
      case .reading:
        return String(
          localized: "Reading part \(progress.current) of \(progress.total)…", bundle: .module)
      case .editing:
        return String(
          localized: "Editing part \(progress.current) of \(progress.total)…", bundle: .module)
      case .reviewing:
        return String(
          localized: "Reviewing part \(progress.current) of \(progress.total)…", bundle: .module)
      }
    }

    private var answer: some View {
      ForEach(Array(state.answerParts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .prose(let text):
          Section { Text(text).textSelection(.enabled) }
        case .quotation(let quote, let ranges):
          Section {
            Text(quote).textSelection(.enabled)
            if ranges.count == 1, let range = ranges.first {
              Button(
                String(localized: "Show in File", bundle: .module), systemImage: "arrow.up.forward"
              ) { reveal(range) }
              .disabled(!state.canReveal(range))
            } else if ranges.count > 1 {
              Menu(
                String(localized: "Show in File", bundle: .module), systemImage: "arrow.up.forward"
              ) {
                ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                  Button(String(localized: "Match \(index + 1)", bundle: .module)) {
                    reveal(range)
                  }
                  .disabled(!state.canReveal(range))
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
                "\(proposal.omittedCount) changes couldn't be found in your file and won't be applied.",
              bundle: .module),
            systemImage: "exclamationmark.circle")
        }
      }
      if proposal.changes.isEmpty, state.appliedCount == 0 {
        Section {
          Text(
            state.action == .edit
              ? String(localized: "No edits needed.", bundle: .module)
              : String(localized: "No comments.", bundle: .module)
          )
          .foregroundStyle(.secondary)
        }
      }
      ForEach(Array(proposal.changes.enumerated()), id: \.element.id) { index, change in
        Section {
          self.change(change)
        } header: {
          if index == 0, state.action == .review {
            Text(
              proposal.changes.count == 1
                ? String(localized: "1 comment", bundle: .module)
                : String(localized: "\(proposal.changes.count) comments", bundle: .module))
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

    @ViewBuilder
    private func change(_ change: Proposal.Change) -> some View {
      let comparison = change.replacement.map { TextDiff(before: change.quote, after: $0) }
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
          Text(DiffText.attributed(comparison.before)).textSelection(.enabled)
        } else {
          Text(change.quote).textSelection(.enabled)
        }
      }
      if let replacement = change.replacement, let comparison {
        VStack(alignment: .leading, spacing: 6) {
          Text("After", bundle: .module).font(.caption).fontWeight(.semibold)
          if replacement.isEmpty {
            Text("Remove this text", bundle: .module).foregroundStyle(.secondary)
          } else {
            Text(DiffText.attributed(comparison.after)).textSelection(.enabled)
          }
        }
      }
      if change.range == nil {
        Label(String(localized: "Can't Apply", bundle: .module), systemImage: "exclamationmark.circle")
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
      guard state.canReveal(range) else { return }
      revealSource(range)
      dismiss()
    }
  }
#endif
