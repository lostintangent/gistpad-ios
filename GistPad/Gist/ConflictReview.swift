import Foundation
import GistPadSync
import SwiftUI

struct ConflictTarget: Identifiable {
  var id: UUID { review.id }
  let session: FileSession
  let review: Conflict
}

struct ConflictReview: View {
  let session: FileSession
  @State private var review: Conflict
  @State private var tab = ReviewTab.changes
  @State private var isApplying = false
  @State private var isConfirmingRemote = false
  @State private var error: String?
  @State private var localChanges: [DiffLine] = []
  @State private var remoteChanges: [DiffLine] = []
  @State private var isComparing = true
  @Environment(\.dismiss) private var dismiss

  init(session: FileSession, review: Conflict) {
    self.session = session
    _review = State(initialValue: review)
  }

  private var isStale: Bool {
    session.editor.generation != review.draft.generation || !review.matches(session.draft)
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
            Button("Review Latest Draft") {
              do {
                review = try session.reviewContext()
                error = nil
              } catch { self.error = error.localizedDescription }
            }
          }
          if let error {
            Label(error, systemImage: "exclamationmark.circle")
          }
          Picker("Version", selection: $tab) {
            ForEach(ReviewTab.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          switch tab {
          case .changes:
            if isComparing {
              ProgressView()
            } else {
              changes(title: String(localized: "On this iPhone"), lines: localChanges)
              changes(title: String(localized: "On GitHub"), lines: remoteChanges)
            }
          case .local:
            source(review.conflict.local)
          case .remote:
            source(review.conflict.remote ?? "")
          }
          if review.conflict.remote != nil {
            Text(
              "Both versions changed the same passage. Choose a version, or return to your draft to combine the changes yourself."
            )
          }
          VStack(alignment: .leading, spacing: 12) {
            Button("Keep Mine") { apply(review.conflict.local, publishes: true) }
              .buttonStyle(.borderedProminent)
            Button("Use GitHub's") { isConfirmingRemote = true }
              .buttonStyle(.bordered)
          }
          .disabled(isStale || !session.canMutate)
          if !session.canMutate {
            Text("Finish the current edit to apply this version.")
          }
        }
        .padding(20)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle("Review Changes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) { dismiss() }.disabled(isApplying)
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
            DiffLine.changes(from: conflict.base, to: conflict.local),
            DiffLine.changes(from: conflict.base, to: conflict.remote ?? "")
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

  private func changes(title: String, lines: [DiffLine]) -> some View {
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
        try await session.applyReview(review, text: text, publishes: publishes)
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
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

struct DiffLine: Identifiable, Sendable {
  var id: String { "\(isAddition)/\(offset)" }
  let isAddition: Bool
  let offset: Int
  let text: String

  static func changes(from base: String?, to text: String) -> [DiffLine] {
    let original = lines(in: base ?? "")
    let updated = lines(in: text)
    return updated.difference(from: original).map { change in
      switch change {
      case .insert(let offset, let element, _):
        DiffLine(
          isAddition: true, offset: offset, text: String(decoding: element, as: UTF8.self))
      case .remove(let offset, let element, _):
        DiffLine(
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
