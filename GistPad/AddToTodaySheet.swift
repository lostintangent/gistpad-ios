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
  @Environment(\.dismiss) private var dismiss

  init(target: DailyNoteTarget = DailyNoteTarget()) {
    self.target = target
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $text)
            .frame(minHeight: 140)
            .focused($isFocused)
            .accessibilityLabel("Text to add to Today")
          Picker("Add as", selection: $asTask) {
            Text("Text").tag(false)
            Text("Task").tag(true)
          }
          .pickerStyle(.segmented)
        } header: {
          Text(target.filename.replacingOccurrences(of: ".md", with: ""))
        }
        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .accessibilityIdentifier("today-capture-error")
          }
        }
      }
      .navigationTitle("Add to Today")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
            .disabled(isAdding)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add", systemImage: "plus") { add() }
            .disabled(isAdding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .disabled(isAdding)
      .interactiveDismissDisabled(isAdding)
      .task { isFocused = true }
    }
    .presentationDetents([.medium, .large])
  }

  private func add() {
    isAdding = true
    errorMessage = nil
    Task {
      do {
        try await NotebookIntentRuntime.service().addToToday(
          text: text, asTask: asTask, target: target)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isAdding = false
      }
    }
  }
}
