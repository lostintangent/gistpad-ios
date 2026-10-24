#if canImport(UIKit)
  import GistPadIntelligence
  import GistPadInterface
  import SwiftUI
  import UIKit

  @MainActor
  public struct NoteIntelligenceSheet: View {
    private let title: String
    private let filename: String
    private let revealSource: @MainActor (NSRange) -> Void
    private let initialPromptFocus: Bool
    @State private var model: NoteIntelligenceModel
    @State private var detent = PresentationDetent.medium
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var promptFocused: Bool

    public init(
      session: DocumentSession, title: String, filename: String,
      backend: (any NoteModelBackend)? = nil,
      isCurrent: @escaping @MainActor () -> Bool,
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.title = title
      self.filename = filename
      self.revealSource = revealSource
      initialPromptFocus = false
      _model = State(
        initialValue: NoteIntelligenceModel(
          session: session, backend: backend ?? AppleNoteModel(), isCurrent: isCurrent))
    }

    init(
      model: NoteIntelligenceModel, title: String, filename: String,
      initialPromptFocus: Bool = false,
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.title = title
      self.filename = filename
      self.revealSource = revealSource
      self.initialPromptFocus = initialPromptFocus
      _model = State(initialValue: model)
    }

    @ViewBuilder
    private var actionPicker: some View {
      if dynamicTypeSize.isAccessibilitySize {
        actionChoices.pickerStyle(.menu)
      } else {
        actionChoices.pickerStyle(.segmented)
      }
    }

    private var actionChoices: some View {
      @Bindable var model = model
      return Picker(String(localized: "Action", bundle: .module), selection: $model.action) {
        Text("Ask", bundle: .module).tag(NoteIntelligenceAction.ask)
        Text("Edit", bundle: .module).tag(NoteIntelligenceAction.edit)
          .disabled(!model.session.textView.isEditable)
        Text("Review", bundle: .module).tag(NoteIntelligenceAction.review)
      }
    }

    public var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            identification
            if let reason = model.availabilityReason {
              issue(reason, symbol: "apple.intelligence")
              Button(String(localized: "Check Again", bundle: .module)) {
                Task { await model.checkAvailability() }
              }
            }
            actionPicker
              .disabled(model.isRunning)
              .accessibilityIdentifier("intelligence-actions")
            if let error = model.errorMessage { issue(error, symbol: "exclamationmark.circle") }
            if model.action != .review || !model.hasResults || model.isRunning
              || !model.session.textView.isEditable
            {
              request
            }
            if model.isRunning { generationProgress }
            if model.isStale, model.snapshot != nil {
              issue(
                String(
                  localized:
                    "This note changed. Generate a fresh result before applying or opening a reference.",
                  bundle: .module),
                symbol: "arrow.clockwise")
            }
            if !model.answerParts.isEmpty { answer }
            if model.action == .review, let proposal = model.proposal {
              Text(
                proposal.comments.count == 1
                  ? String(localized: "1 suggestion", bundle: .module)
                  : String(localized: "\(proposal.comments.count) suggestions", bundle: .module)
              )
              .font(.headline)
            }
            if let proposal = model.appliedEdit ?? model.proposal { changes(proposal) }
            if let notice = model.notice {
              Label(
                notice, systemImage: model.appliedCount > 0 ? "checkmark.circle" : "info.circle"
              )
              .font(.callout)
              .foregroundStyle(.secondary)
            }
            if model.hasResults, !model.isRunning {
              generateButton
            }
          }
          .padding(20)
          .frame(maxWidth: 680, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: .module), systemImage: "xmark") {
              model.cancel()
              dismiss()
            }
            .labelStyle(.iconOnly)
            .tint(.primary)
          }
        }
      }
      .tint(InterfaceTheme.accent)
      .presentationDetents([.medium, .large], selection: $detent)
      .presentationDragIndicator(.visible)
      .sensoryFeedback(.success, trigger: model.applyFeedback)
      .task {
        if dynamicTypeSize.isAccessibilitySize
          || (model.action != .ask && model.hasResults)
        {
          detent = .large
        }
        await model.checkAvailability()
        if initialPromptFocus, model.available, model.action != .review {
          promptFocused = true
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.checkAvailability() } }
      }
      .onChange(of: model.action) { _, _ in model.clearResults() }
      .onChange(of: model.proposal != nil) { _, exists in
        if exists { detent = .large }
      }
      .onChange(of: dynamicTypeSize) { _, size in
        if size.isAccessibilitySize { detent = .large }
      }
      .onDisappear { model.cancel() }
      .accessibilityIdentifier("note-intelligence-sheet")
    }

    private var identification: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          Text(filename)
          Label(String(localized: "On device", bundle: .module), systemImage: "iphone")
        }
        .fixedSize()
        VStack(alignment: .leading, spacing: 6) {
          Text(filename).fixedSize(horizontal: false, vertical: true)
          Label(String(localized: "On device", bundle: .module), systemImage: "iphone")
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    }

    private var request: some View {
      @Bindable var model = model
      return VStack(alignment: .leading, spacing: 12) {
        if model.action == .review {
          if !model.hasResults {
            Text("Find errors and unclear wording.", bundle: .module)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        } else if model.hasResults {
          VStack(alignment: .leading, spacing: 8) {
            Text(model.submittedPrompt ?? model.prompt)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityLabel(model.submittedPrompt ?? model.prompt)
              .accessibilityIdentifier("intelligence-submitted-request")
            Button(String(localized: "Edit Request", bundle: .module)) {
              model.clearResults()
              promptFocused = true
            }
            .font(.callout)
            .disabled(model.isRunning)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          TextField(
            model.action == .ask
              ? String(localized: "Ask about this note", bundle: .module)
              : String(localized: "What would you like to change?", bundle: .module),
            text: $model.prompt, axis: .vertical
          )
          .lineLimit(2...5)
          .padding(14)
          .background(
            Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14)
          )
          .focused($promptFocused)
          .disabled(model.isRunning)
          .accessibilityIdentifier("intelligence-prompt")
        }
        if model.isRunning {
          Button(String(localized: "Cancel", bundle: .module), role: .cancel) { model.cancel() }
            .disabled(model.isCancelling)
        } else if !model.hasResults {
          generateButton
        }
        if !model.session.textView.isEditable {
          Text(
            "Read-only note. You can ask and review, but changes can't be applied.", bundle: .module
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    }

    @ViewBuilder
    private var generateButton: some View {
      if model.hasResults {
        generateAction.buttonStyle(.glass)
      } else {
        generateAction
          .buttonStyle(.glassProminent)
          .tint(InterfaceTheme.accentFill)
          .foregroundStyle(InterfaceTheme.onAccent)
      }
    }

    private var generateAction: some View {
      Button(generateLabel, systemImage: "sparkles") {
        promptFocused = false
        model.generate()
      }
      .disabled(!model.canGenerate)
      .accessibilityIdentifier("intelligence-generate")
    }

    private var generateLabel: String {
      if model.errorMessage != nil { return String(localized: "Try Again", bundle: .module) }
      if model.hasResults {
        return switch model.action {
        case .ask: String(localized: "Ask Again", bundle: .module)
        case .edit: String(localized: "Propose Again", bundle: .module)
        case .review: String(localized: "Review Again", bundle: .module)
        }
      }
      return switch model.action {
      case .ask: String(localized: "Ask", bundle: .module)
      case .edit: String(localized: "Propose Changes", bundle: .module)
      case .review: String(localized: "Review Note", bundle: .module)
      }
    }

    private var generationProgress: some View {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text(progressLabel).font(.callout).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }

    private var progressLabel: String {
      if model.isCancelling { return String(localized: "Stopping…", bundle: .module) }
      guard let progress = model.progress else {
        return String(localized: "Preparing this note…", bundle: .module)
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
      VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(model.answerParts.enumerated()), id: \.offset) { _, part in
          switch part {
          case .prose(let text):
            Text(text).textSelection(.enabled)
          case .quotation(let citation):
            VStack(alignment: .leading, spacing: 8) {
              Text(citation.quote).textSelection(.enabled)
              if citation.ranges.count == 1, let range = citation.ranges.first {
                Button(
                  String(localized: "Show in Note", bundle: .module),
                  systemImage: "arrow.up.forward"
                ) {
                  reveal(range)
                }
                .font(.callout)
                .disabled(!model.canReveal(range))
              } else {
                Menu(
                  String(localized: "Show in Note", bundle: .module),
                  systemImage: "arrow.up.forward"
                ) {
                  ForEach(Array(citation.ranges.enumerated()), id: \.offset) { index, range in
                    Button(String(localized: "Match \(index + 1)", bundle: .module)) {
                      reveal(range)
                    }
                    .disabled(!model.canReveal(range))
                  }
                }
                .font(.callout)
              }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
          }
        }
      }
      .accessibilityIdentifier("intelligence-answer")
    }

    private func changes(_ proposal: NoteProposal) -> some View {
      VStack(alignment: .leading, spacing: 16) {
        if proposal.omittedCount > 0 {
          Text(
            "\(proposal.omittedCount) suggestions couldn't be safely anchored and won't be applied.",
            bundle: .module
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        if proposal.comments.isEmpty, model.appliedCount == 0 {
          Text("No changes suggested.", bundle: .module).foregroundStyle(.secondary)
        }
        ForEach(proposal.comments) { comment in
          let comparison = comment.replacement.map {
            NoteTextDiff(before: comment.quote, after: $0)
          }
          VStack(alignment: .leading, spacing: 12) {
            Text(comment.reason).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
              Text(
                comment.rejection != nil
                  ? String(localized: "Unverified Quote", bundle: .module)
                  : String(localized: "Before", bundle: .module)
              )
              .font(.caption).fontWeight(.semibold)
              if comment.quote.isEmpty {
                Text("Empty note", bundle: .module).foregroundStyle(.secondary)
              } else {
                if let comparison {
                  Text(NoteIntelligenceDiffText.attributed(comparison.before))
                    .textSelection(.enabled)
                } else {
                  Text(comment.quote).textSelection(.enabled)
                }
              }
            }
            if let replacement = comment.replacement, let comparison {
              VStack(alignment: .leading, spacing: 6) {
                Text("After", bundle: .module).font(.caption).fontWeight(.semibold)
                if replacement.isEmpty {
                  Text("Remove this text", bundle: .module).foregroundStyle(.secondary)
                } else {
                  Text(NoteIntelligenceDiffText.attributed(comparison.after))
                    .textSelection(.enabled)
                }
              }
            }
            if comment.rejection != nil {
              Label(
                String(localized: "Unanchored", bundle: .module),
                systemImage: "exclamationmark.circle"
              )
              .font(.callout)
              .foregroundStyle(.secondary)
            } else if model.action == .review, comment.canApply {
              Button(String(localized: "Apply Change", bundle: .module)) {
                model.apply(commentID: comment.id)
              }
              .buttonStyle(.glass)
              .disabled(!model.canApply)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        if model.action == .edit, model.appliedEdit == nil, proposal.canApply {
          Button(String(localized: "Apply Changes", bundle: .module), systemImage: "checkmark") {
            model.apply()
          }
          .buttonStyle(.glassProminent)
          .tint(InterfaceTheme.accentFill)
          .foregroundStyle(InterfaceTheme.onAccent)
          .disabled(!model.canApply)
          .accessibilityIdentifier("intelligence-apply")
        }
      }
    }

    private func issue(_ message: String, symbol: String) -> some View {
      Label(message, systemImage: symbol)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func reveal(_ range: NSRange) {
      guard model.canReveal(range) else { return }
      revealSource(range)
      dismiss()
    }
  }

  enum NoteIntelligenceDiffText {
    static func attributed(_ runs: [NoteTextDiff.Run]) -> AttributedString {
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
          text.foregroundColor = InterfaceTheme.accent
          text.font = .body.weight(.semibold)
        }
        result += text
      }
      return result
    }
  }
#endif
