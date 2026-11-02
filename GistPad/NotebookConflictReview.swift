import Foundation
import GistPadSync
import SwiftUI

struct NotebookConflictTarget: Identifiable {
  var id: UUID { review.id }
  let controller: NotebookSessionController
  let review: NotebookReviewContext
}

struct NotebookConflictReview: View {
  let controller: NotebookSessionController
  @State private var review: NotebookReviewContext
  @State private var tab = ReviewTab.changes
  @State private var isApplying = false
  @State private var isConfirmingRemote = false
  @State private var error: String?
  @State private var remoteChanged = false
  @State private var localChanges: [NotebookDiffLine] = []
  @State private var remoteChanges: [NotebookDiffLine] = []
  @State private var isComparing = true
  @Environment(\.dismiss) private var dismiss

  init(controller: NotebookSessionController, review: NotebookReviewContext) {
    self.controller = controller
    _review = State(initialValue: review)
  }

  private var isStale: Bool {
    controller.session.generation != review.draft.generation || !review.matches(controller.draft)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(verbatim: review.draft.filename).font(.headline)
          Text("Your draft is saved on this iPhone.")
          if isStale {
            Label(
              "Your draft changed while this review was open. Review the latest draft.",
              systemImage: "exclamationmark.circle")
            Button("Review latest draft") {
              do {
                review = try controller.reviewContext()
                error = nil
              } catch { self.error = NotebookModel.message(for: error) }
            }
            .tint(.primary)
          }
          if let error {
            Label(error, systemImage: "exclamationmark.circle")
          }
          if remoteChanged {
            Button("Refresh GitHub version") { refreshRemote() }
              .tint(.primary)
          }
          Picker("Version", selection: $tab) {
            ForEach(ReviewTab.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          .tint(.primary)
          switch tab {
          case .changes:
            if isComparing {
              ProgressView("Comparing source")
            } else {
              changes(title: String(localized: "On this iPhone"), lines: localChanges)
              changes(title: String(localized: "On GitHub"), lines: remoteChanges)
            }
          case .local:
            source(review.conflict.local)
          case .remote:
            source(review.conflict.remote ?? "")
          }
          DisclosureGroup("Show original") {
            if let base = review.conflict.base {
              source(base)
            } else {
              Text("There was no saved file when this local draft was created.")
            }
          }
          .tint(.primary)
          if review.conflict.remote != nil {
            Text(
              "Both versions changed the same passage. Choose a version, or return to your draft to combine the changes yourself."
            )
          }
          VStack(alignment: .leading, spacing: 12) {
            Button {
              apply(review.conflict.local, publishes: true)
            } label: {
              Text("Keep Mine")
                .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(uiColor: .label))
            Button("Use GitHub's") { isConfirmingRemote = true }
              .buttonStyle(.bordered)
              .tint(.primary)
          }
          .disabled(isStale || !controller.canMutate)
          if !controller.canMutate {
            Text("Finish the current edit to apply this version.")
          }
        }
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(Color(uiColor: .systemBackground))
      .navigationTitle("Review changes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }.disabled(isApplying)
            .tint(.primary)
        }
        ToolbarItem(placement: .secondaryAction) {
          Button("Refresh GitHub", systemImage: "arrow.clockwise", action: refreshRemote)
            .tint(.primary)
            .disabled(isStale || isApplying)
        }
      }
      .disabled(isApplying)
      .interactiveDismissDisabled(isApplying)
      .confirmationDialog(
        "Replace your local draft with the GitHub version?",
        isPresented: $isConfirmingRemote, titleVisibility: .visible
      ) {
        Button("Use GitHub's", role: .destructive) {
          apply(review.conflict.remote ?? "", publishes: false)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Replace your text with GitHub's version. You can undo this."
        )
      }
      .task(id: review) {
        isComparing = true
        let conflict = review.conflict
        let diffs = await Task.detached(priority: .userInitiated) {
          (
            NotebookDiffLine.changes(from: conflict.base, to: conflict.local),
            NotebookDiffLine.changes(from: conflict.base, to: conflict.remote ?? "")
          )
        }.value
        guard !Task.isCancelled else { return }
        localChanges = diffs.0
        remoteChanges = diffs.1
        isComparing = false
      }
    }
  }

  private func source(_ text: String) -> some View {
    ScrollView(.horizontal) {
      Text(verbatim: text)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func changes(title: String, lines: [NotebookDiffLine]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      if lines.isEmpty {
        Text("No source changes.")
      } else {
        ScrollView(.horizontal) {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
              Text(verbatim: "\(line.isAddition ? "+" : "-") \(line.text)")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(
                  line.isAddition
                    ? String(localized: "Added: \(line.text)")
                    : String(localized: "Removed: \(line.text)"))
            }
          }
          .fixedSize(horizontal: true, vertical: false)
        }
      }
    }
  }

  private func apply(_ text: String, publishes: Bool) {
    guard !isApplying else { return }
    isApplying = true
    Task {
      defer { isApplying = false }
      do {
        try await controller.applyReview(review, text: text, publishes: publishes)
        dismiss()
      } catch {
        self.error = NotebookModel.message(for: error)
        if case NotebookActionError.remoteReviewChanged = error { remoteChanged = true }
      }
    }
  }

  private func refreshRemote() {
    guard !isApplying else { return }
    isApplying = true
    Task {
      defer { isApplying = false }
      do {
        review = try await controller.refreshReview(review)
        error = nil
        remoteChanged = false
      } catch { self.error = NotebookModel.message(for: error) }
    }
  }
}

private enum ReviewTab: CaseIterable, Hashable {
  case changes, local, remote

  var title: String {
    switch self {
    case .changes: String(localized: "Changes")
    case .local: String(localized: "My Draft")
    case .remote: String(localized: "GitHub")
    }
  }
}

struct NotebookDiffLine: Identifiable, Sendable {
  var id: String { "\(isAddition)/\(offset)" }
  let isAddition: Bool
  let offset: Int
  let text: String

  static func changes(from base: String?, to text: String) -> [NotebookDiffLine] {
    let original = lines(in: base ?? "")
    let updated = lines(in: text)
    return updated.difference(from: original).map { change in
      switch change {
      case .insert(let offset, let element, _):
        NotebookDiffLine(
          isAddition: true, offset: offset, text: String(decoding: element, as: UTF8.self))
      case .remove(let offset, let element, _):
        NotebookDiffLine(
          isAddition: false, offset: offset, text: String(decoding: element, as: UTF8.self))
      }
    }.sorted {
      if $0.isAddition != $1.isAddition { return !$0.isAddition }
      return $0.offset < $1.offset
    }
  }

  private static func lines(in text: String) -> [Data] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { Data($0.utf8) }
  }
}
