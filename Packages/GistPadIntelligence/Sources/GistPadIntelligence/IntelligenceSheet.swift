#if canImport(UIKit)
  import GistPadEditor
  import SwiftUI
  import UIKit

  public struct IntelligenceSheet: View {
    private let title: String
    private let revealSource: @MainActor (NSRange) -> Void
    @State private var model: IntelligenceState
    @State private var detent = PresentationDetent.medium
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var promptFocused: Bool

    public init(
      session: Editor, title: String,
      backend: any IntelligenceModel = OnDeviceModel(),
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.title = title
      self.revealSource = revealSource
      _model = State(initialValue: IntelligenceState(session: session, backend: backend))
    }

    public var body: some View {
      @Bindable var model = model
      NavigationStack {
        Form {
          Section {
            Picker(String(localized: "Action", bundle: .module), selection: $model.action) {
              Text("Ask", bundle: .module).tag(IntelligenceAction.ask)
              Text("Edit", bundle: .module).tag(IntelligenceAction.edit)
                .disabled(!model.session.textView.isEditable)
              Text("Review", bundle: .module).tag(IntelligenceAction.review)
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            .accessibilityIdentifier("intelligence-actions")
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
          request
          if let reason = model.availabilityReason {
            Section { Label(reason, systemImage: "apple.intelligence") }
          }
          if let error = model.errorMessage {
            Section { Label(error, systemImage: "exclamationmark.circle") }
          }
          if model.isRunning {
            Section {
              LabeledContent(progressLabel) { ProgressView() }
                .accessibilityIdentifier("intelligence-progress")
            }
          }
          if model.isStale, model.snapshot != nil {
            Section {
              Label(
                String(localized: "This file has changed since this result.", bundle: .module),
                systemImage: "arrow.clockwise")
            }
          }
          answer
          if let review = model.appliedEdit ?? model.review { changes(review) }
          if let notice = model.notice {
            Section {
              Label(
                notice, systemImage: model.appliedCount > 0 ? "checkmark.circle" : "info.circle")
            }
          }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) {
              model.cancel()
              dismiss()
            }
            .accessibilityIdentifier("intelligence-close")
          }
          ToolbarItem(placement: .confirmationAction) {
            if model.isRunning {
              Button(String(localized: "Stop", bundle: .module), systemImage: "stop.fill") {
                model.cancel()
              }
              .disabled(model.isCancelling)
              .accessibilityIdentifier("intelligence-cancel")
            } else {
              Button(verb, role: .confirm) {
                promptFocused = false
                model.generate()
              }
              .disabled(!model.canGenerate)
              .accessibilityIdentifier("intelligence-generate")
            }
          }
        }
      }
      .presentationDetents([.medium, .large], selection: $detent)
      .presentationDragIndicator(.visible)
      .sensoryFeedback(.success, trigger: model.applyFeedback)
      .task {
        if dynamicTypeSize.isAccessibilitySize { detent = .large }
        await model.checkAvailability()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.checkAvailability() } }
      }
      .onChange(of: model.action) {
        model.clearResults()
        Task { await model.checkAvailability() }
      }
      .onChange(of: model.isRunning || model.review != nil || dynamicTypeSize.isAccessibilitySize)
      { _, expands in
        if expands { detent = .large }
      }
      .onDisappear { model.cancel() }
      .accessibilityIdentifier("note-intelligence-sheet")
    }

    private var verb: String {
      switch model.action {
      case .ask: String(localized: "Ask", bundle: .module)
      case .edit: String(localized: "Edit", bundle: .module)
      case .review: String(localized: "Review", bundle: .module)
      }
    }

    @ViewBuilder
    private var request: some View {
      @Bindable var model = model
      Section {
        switch model.action {
        case .review:
          if !model.hasResults {
            Text("Find errors and unclear wording.", bundle: .module)
              .foregroundStyle(.secondary)
          }
        case .ask, .edit:
          TextField(
            model.action == .ask
              ? String(localized: "Ask about this file", bundle: .module)
              : String(localized: "What would you like to change?", bundle: .module),
            text: $model.prompt, axis: .vertical
          )
          .lineLimit(1...5)
          .focused($promptFocused)
          .disabled(model.isRunning)
          .accessibilityIdentifier("intelligence-prompt")
        }
      } footer: {
        if !model.session.textView.isEditable {
          Text(
            "This gist is read-only. You can ask and review, but not apply changes.",
            bundle: .module)
        }
      }
    }

    private var progressLabel: String {
      if model.isCancelling { return String(localized: "Stopping…", bundle: .module) }
      guard let progress = model.progress else {
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
      ForEach(Array(model.answerParts.enumerated()), id: \.offset) { _, part in
        switch part {
        case .prose(let text):
          Section { Text(text).textSelection(.enabled) }
        case .quotation(let citation):
          let ranges = citation.ranges.filter { !model.isHiddenFrontMatterReference($0) }
          Section {
            Text(citation.quote).textSelection(.enabled)
            if ranges.count == 1, let range = ranges.first {
              Button(
                String(localized: "Show in File", bundle: .module), systemImage: "arrow.up.forward"
              ) { reveal(range) }
              .disabled(!model.canReveal(range))
            } else if ranges.count > 1 {
              Menu(
                String(localized: "Show in File", bundle: .module), systemImage: "arrow.up.forward"
              ) {
                ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                  Button(String(localized: "Match \(index + 1)", bundle: .module)) {
                    reveal(range)
                  }
                  .disabled(!model.canReveal(range))
                }
              }
            }
          } footer: {
            if !citation.ranges.isEmpty, ranges.isEmpty {
              Text("Front matter", bundle: .module)
                .accessibilityIdentifier("intelligence-front-matter-reference")
            }
          }
        }
      }
    }

    @ViewBuilder
    private func changes(_ review: Review) -> some View {
      if review.omittedCount > 0 {
        Section {
          Label(
            String(
              localized:
                "\(review.omittedCount) changes couldn't be found in your file and won't be applied.",
              bundle: .module),
            systemImage: "exclamationmark.circle")
        }
      }
      if review.comments.isEmpty, model.appliedCount == 0 {
        Section {
          Text(
            model.action == .edit
              ? String(localized: "No edits needed.", bundle: .module)
              : String(localized: "No comments.", bundle: .module)
          )
          .foregroundStyle(.secondary)
        }
      }
      ForEach(Array(review.comments.enumerated()), id: \.element.id) { index, comment in
        Section {
          change(comment)
        } header: {
          if index == 0, model.action == .review {
            Text(
              review.comments.count == 1
                ? String(localized: "1 comment", bundle: .module)
                : String(localized: "\(review.comments.count) comments", bundle: .module))
          }
        }
      }
      if model.action == .edit, model.appliedEdit == nil, review.canApply {
        Section {
          Button(String(localized: "Apply Edit", bundle: .module), systemImage: "checkmark") {
            model.apply()
          }
          .disabled(!model.canApply)
          .accessibilityIdentifier("intelligence-apply")
        }
      }
    }

    @ViewBuilder
    private func change(_ comment: Review.Comment) -> some View {
      let comparison = comment.replacement.map { TextDiff(before: comment.quote, after: $0) }
      Text(comment.reason).font(.headline)
      VStack(alignment: .leading, spacing: 6) {
        Text(
          comment.rejection != nil
            ? String(localized: "Unverified Quote", bundle: .module)
            : String(localized: "Before", bundle: .module)
        )
        .font(.caption).fontWeight(.semibold)
        if comment.quote.isEmpty {
          Text("Empty file", bundle: .module).foregroundStyle(.secondary)
        } else if let comparison {
          Text(DiffText.attributed(comparison.before)).textSelection(.enabled)
        } else {
          Text(comment.quote).textSelection(.enabled)
        }
      }
      if let replacement = comment.replacement, let comparison {
        VStack(alignment: .leading, spacing: 6) {
          Text("After", bundle: .module).font(.caption).fontWeight(.semibold)
          if replacement.isEmpty {
            Text("Remove this text", bundle: .module).foregroundStyle(.secondary)
          } else {
            Text(DiffText.attributed(comparison.after)).textSelection(.enabled)
          }
        }
      }
      if comment.rejection != nil {
        Label(String(localized: "Can't Apply", bundle: .module), systemImage: "exclamationmark.circle")
          .foregroundStyle(.secondary)
      }
      if model.action == .review {
        if comment.canApply {
          Button(String(localized: "Apply", bundle: .module)) {
            model.apply(commentID: comment.id)
          }
          .disabled(!model.canApply)
        }
        Button(String(localized: "Dismiss", bundle: .module)) {
          model.dismiss(commentID: comment.id)
        }
        .disabled(model.isRunning)
      }
    }

    private func reveal(_ range: NSRange) {
      guard model.canReveal(range) else { return }
      revealSource(range)
      dismiss()
    }
  }
#endif
