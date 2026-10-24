import GistPadInterface
import GistPadSync
import SwiftUI

struct NotebookSettingsSheet<Appearance: View>: View {
  let account: NotebookAccount?
  let savePreference: @MainActor (BooleanPreference, Bool) async throws -> Void
  let connect: @MainActor () -> Void
  @ViewBuilder var appearance: () -> Appearance
  @State private var pendingPreference: BooleanPreference?
  @State private var pendingValue = false
  @State private var saveError: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let account {
            LabeledContent("GitHub", value: "@\(account.login)")
              .accessibilityIdentifier("settings-account")
          } else {
            Label("Connect your notebook", systemImage: "person.crop.circle")
            Text("Sign in to open your GitHub gists, daily notes and saved tags.")
              .foregroundStyle(.secondary)
            Button("Sign In with GitHub", action: connect)
              .accessibilityIdentifier("settings-sign-in")
          }
        } header: {
          Text("Account")
        }
        if account != nil {
          Section {
            Toggle("Autosave While Writing", isOn: preference(.isAutoSaveEnabled, default: true))
              .accessibilityIdentifier("settings-autosave")
          } header: {
            Text("Saving")
          } footer: {
            Text(
              "Edits are always kept on this iPhone. When enabled, a 5-second pause or leaving a note saves to GitHub. Leaving the app saves even when this is off.")
          }
          Section("Writing") {
            Toggle("Check Spelling", isOn: preference(.isSpellcheckEnabled, default: true))
              .accessibilityIdentifier("settings-spelling")
          }
          Section("Appearance") { appearance() }
        }
        if account != nil {
          Section {
            Button("Switch GitHub Account", action: connect)
              .accessibilityIdentifier("settings-switch-account")
          } footer: {
            Text("Drafts stay on this iPhone with their original account. Switching never publishes them.")
          }
        }
      }
      .disabled(pendingPreference != nil)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .close) { dismiss() }
            .accessibilityLabel("Close Settings")
        }
      }
      .alert(
        "Couldn't Confirm Setting",
        isPresented: Binding(
          get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button("OK") { saveError = nil }
      } message: {
        Text(saveError ?? "")
      }
    }
  }

  private func preference(_ key: BooleanPreference, default fallback: Bool) -> Binding<Bool> {
    Binding(
      get: {
        pendingPreference == key
          ? pendingValue : account?.preferences.metadata[key.rawValue]?.boolValue ?? fallback
      },
      set: { value in
        guard pendingPreference == nil else { return }
        pendingPreference = key
        pendingValue = value
        saveError = nil
        Task {
          defer { pendingPreference = nil }
          do {
            try await savePreference(key, value)
          } catch {
            saveError = NotebookModel.message(for: error)
          }
        }
      })
  }
}
