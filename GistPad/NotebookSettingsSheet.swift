import GistPadInterface
import GistPadInterface
import GistPadSync
import SwiftUI

struct NotebookSettingsSheet<Appearance: View>: View {
  let account: NotebookAccount?
  let savePreference: @MainActor (BooleanPreference, Bool) async throws -> Void
  let connect: @MainActor () -> Void
  let signOut: @MainActor () async throws -> Void
  @ViewBuilder var appearance: () -> Appearance
  @State private var pendingPreference: BooleanPreference?
  @State private var pendingValue = false
  @State private var saveError: String?
  @State private var errorTitle = String(localized: "Couldn't Confirm Setting")
  @State private var confirmingSignOut = false
  @State private var isSigningOut = false
  @Environment(\.dismiss) private var dismiss

  #if DEBUG
  func captureSignOutConfirmation(_ presented: Bool) -> Self {
    var sheet = self
    sheet._confirmingSignOut = State(initialValue: presented)
    return sheet
  }
  #endif

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let account {
            HStack(spacing: 14) {
              AsyncImage(url: account.avatarURL) { phase in
                if let image = phase.image {
                  image.resizable().scaledToFill()
                } else {
                  Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
                }
              }
              .frame(width: 44, height: 44)
              .clipShape(Circle())
              .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 3) {
                if let name = account.displayName {
                  Text(verbatim: name).font(.headline)
                  Text(verbatim: "@\(account.login)")
                    .font(.subheadline).foregroundStyle(.secondary)
                } else {
                  Text(verbatim: "@\(account.login)")
                }
              }
            }
              .padding(.vertical, 4)
              .accessibilityElement(children: .combine)
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
              "Edits are always kept on this iPhone. When enabled, a 5-second pause or leaving a note saves to GitHub. Leaving the app attempts a save even when this is off.")
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
          Section {
            if isSigningOut {
              ProgressView("Signing Out")
            } else {
              Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                .accessibilityIdentifier("settings-sign-out")
                .captureFrame("settings-sign-out")
            }
          }
        }
      }
      .disabled(isWorking)
      .interactiveDismissDisabled(isWorking)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .close) { dismiss() }
            .accessibilityLabel("Close Settings")
            .tint(.primary)
            .disabled(isWorking)
        }
      }
      .alert(
        "Sign Out?",
        isPresented: $confirmingSignOut
      ) {
        Button("Sign Out", role: .destructive, action: confirmSignOut)
        Button("Cancel", role: .cancel) {}
          .tint(.primary)
      } message: {
        Text("Drafts for @\(account?.login ?? "") stay on this iPhone. Nothing is published.")
      }
      .alert(
        errorTitle,
        isPresented: Binding(
          get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button("OK") { saveError = nil }
      } message: {
        Text(saveError ?? "")
      }
    }
    .tint(InterfaceTheme.accent)
  }

  private var isWorking: Bool { pendingPreference != nil || isSigningOut }

  private func confirmSignOut() {
    guard !isWorking else { return }
    isSigningOut = true
    saveError = nil
    errorTitle = String(localized: "Couldn't Sign Out")
    Task {
      defer { isSigningOut = false }
      do {
        try await signOut()
        dismiss()
      } catch {
        saveError = NotebookModel.message(for: error)
      }
    }
  }

  private func preference(_ key: BooleanPreference, default fallback: Bool) -> Binding<Bool> {
    Binding(
      get: {
        pendingPreference == key
          ? pendingValue : account?.preferences.booleanValue(key, default: fallback) ?? fallback
      },
      set: { value in
        guard pendingPreference == nil else { return }
        pendingPreference = key
        pendingValue = value
        saveError = nil
        errorTitle = String(localized: "Couldn't Confirm Setting")
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
