import GistPadInterface
import GistPadPlatform
import GistPadSync
import SwiftUI
import UIKit

struct AddToTodaySheet: View {
  let target: DailyNoteTarget
  @State private var text = ""
  @State private var asTask = false
  @State private var isAdding = false
  @State private var errorMessage: String?
  @FocusState private var isFocused: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(target: DailyNoteTarget = DailyNoteTarget()) {
    self.target = target
  }

  var body: some View {
    NavigationStack {
      Form {
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
        Section {
          TextField(
            text: $text, prompt: Text(asTask ? "Add a task…" : "Write a thought…"), axis: .vertical
          ) {
            asTask ? Text("Task to add to Today") : Text("Text to add to Today")
          }
          .lineLimit(5...)
          .focused($isFocused)
          .accessibilityIdentifier("today-capture-input")
          kindPicker
        } header: {
          destinationDate
        }
      }
      .navigationTitle("Add to Today")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarVisibility(.visible, for: .navigationBar)
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
            Button(role: .confirm, action: add) {
              Image(systemName: "checkmark")
            }
              .buttonStyle(.glassProminent)
              .tint(Color(uiColor: .label))
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
    .presentationDetents(
      dynamicTypeSize.isAccessibilitySize || errorMessage != nil ? [.large] : [.medium, .large])
  }

  private var kindPicker: some View {
    Picker("Add as", selection: $asTask) {
      Text("Text").tag(false)
      Text("Task").tag(true)
    }
    .pickerStyle(.segmented)
    .tint(.primary)
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
        if let destination = try await NotebookPlatformBootstrap.bridge?.addToToday(
          text: text, asTask: asTask, target: target)
        {
          NotebookRouteInbox.shared.submit(destination)
        }
        dismiss()
      } catch {
        errorMessage = Self.message(for: error)
        isFocused = false
        isAdding = false
      }
    }
  }

  private static func message(for error: Error) -> String {
    if let editError = error as? NotebookEditError,
      case .localPersistenceFailed = editError
    {
      return String(localized: "Your text is still here. Tap Add to try again.")
    }
    return NotebookModel.message(for: error)
  }
}
