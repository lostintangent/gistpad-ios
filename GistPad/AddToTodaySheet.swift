import GistPadInterface
import GistPadPlatform
import GistPadSync
import SwiftUI

struct AddToTodaySheet: View {
  let target: DailyNoteTarget
  @State private var text = ""
  @State private var asTask = false
  @State private var isAdding = false
  @State private var errorMessage: String?
  @FocusState private var isFocused: Bool
  @ScaledMetric(relativeTo: .body) private var writingLineHeight = 22.0
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(target: DailyNoteTarget = DailyNoteTarget()) {
    self.target = target
  }

  #if DEBUG
  static func captureFixture() -> Self {
    let arguments = ProcessInfo.processInfo.arguments
    let state = arguments.firstIndex(of: "--capture-state").flatMap { index in
      arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }
    var sheet = Self()
    sheet._asTask = State(initialValue: state == "task")
    if state == "filled" || state == "error" {
      sheet._text = State(initialValue: "A thought worth keeping.")
    }
    if state == "error" {
      sheet._errorMessage = State(
        initialValue: NotebookModel.message(for: NotebookEditError.localPersistenceFailed))
    }
    return sheet
  }
  #endif

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: max(140, writingLineHeight * 2 + 16))
            .focused($isFocused)
            .overlay(alignment: .topLeading) {
              if text.isEmpty {
                Text(asTask ? "Add a task…" : "Write a thought…")
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 8)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .accessibilityLabel(asTask ? Text("Task to add to Today") : Text("Text to add to Today"))
            .accessibilityIdentifier("today-capture-input")
          if dynamicTypeSize.isAccessibilitySize {
            kindPicker.pickerStyle(.menu)
          } else {
            kindPicker.pickerStyle(.segmented)
          }
        } header: {
          destinationDate
        }
        if let errorMessage {
          Section {
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't Add to Today").font(.headline)
                Text(errorMessage).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "exclamationmark.circle")
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("today-capture-error")
          }
        }
      }
      .navigationTitle("Add to Today")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { dismiss() }
            .accessibilityLabel("Cancel")
            .tint(.primary)
            .disabled(isAdding)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isAdding {
            ProgressView()
              .accessibilityLabel("Adding to Today")
          } else {
            Button(role: .confirm, action: add)
              .accessibilityLabel("Add")
              .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("today-capture-add")
          }
        }
      }
      .disabled(isAdding)
      .interactiveDismissDisabled(isAdding)
      .task { isFocused = errorMessage == nil }
    }
    .presentationDetents([.medium, .large])
    .tint(InterfaceTheme.accent)
  }

  private var kindPicker: some View {
    Picker("Add as", selection: $asTask) {
      Text("Text").tag(false)
      Text("Task").tag(true)
    }
    .accessibilityIdentifier("today-capture-kind")
  }

  @ViewBuilder
  private var destinationDate: some View {
    let timeZone = TimeZone(identifier: target.timeZoneIdentifier) ?? .current
    if let date = DailyNotesIndex.parseDateFilename(target.filename, timeZone: timeZone) {
      Text(
        date,
        format: Date.FormatStyle(calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
          .weekday(.abbreviated).month(.abbreviated).day()
      )
      .font(.caption)
      .textCase(nil)
    } else {
      Text(target.filename)
    }
  }

  private func add() {
    isAdding = true
    errorMessage = nil
    Task {
      do {
        let destination = try await NotebookIntentRuntime.service().addToToday(
          text: text, asTask: asTask, target: target)
        NotebookRouteInbox.shared.submit(destination)
        dismiss()
      } catch {
        errorMessage = NotebookModel.message(for: error)
        isAdding = false
      }
    }
  }
}
