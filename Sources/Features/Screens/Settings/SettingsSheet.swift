#if os(iOS)
import Store
import SwiftUI

public struct SettingsSheet<Appearance: View>: View {
  let account: GistPadAccount?
  let savePreference: @MainActor (BooleanPreference, Bool) async throws -> Void
  let connect: @MainActor () -> Void
  let signOut: @MainActor () async throws -> Void
  @ViewBuilder var appearance: () -> Appearance
  @State private var pendingPreference: (key: BooleanPreference, value: Bool)?
  @State private var saveError: String?
  @State private var errorTitle = String(localized: "Couldn't Confirm Setting", bundle: .module)
  @State private var confirmingSignOut = false
  @State private var isSigningOut = false
  @Environment(\.dismiss) private var dismiss

  public init(
    account: GistPadAccount?,
    savePreference: @escaping @MainActor (BooleanPreference, Bool) async throws -> Void,
    connect: @escaping @MainActor () -> Void,
    signOut: @escaping @MainActor () async throws -> Void,
    @ViewBuilder appearance: @escaping () -> Appearance
  ) {
    self.account = account
    self.savePreference = savePreference
    self.connect = connect
    self.signOut = signOut
    self.appearance = appearance
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section(String(localized: "Account", bundle: .module)) {
          if let account {
            HStack(spacing: 14) {
              AsyncImage(url: account.github.avatarURL) { phase in
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
                  Text(verbatim: "@\(account.github.login)")
                    .font(.subheadline).foregroundStyle(.secondary)
                } else {
                  Text(verbatim: "@\(account.github.login)")
                }
              }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-account")
            if isSigningOut {
              ProgressView(String(localized: "Signing Out", bundle: .module))
            } else {
              Button(
                String(localized: "Sign Out", bundle: .module), systemImage: "rectangle.portrait.and.arrow.forward",
                role: .destructive
              ) { confirmingSignOut = true }
                // The destructive role reddens only the title in a Form, and the icon would keep the accent.
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings-sign-out")
            }
          } else {
            Label(String(localized: "Connect GitHub", bundle: .module), systemImage: "person.crop.circle")
            Text("Sign in to open your GitHub gists, daily notes and saved tags.", bundle: .module)
              .foregroundStyle(.secondary)
            Button(String(localized: "Sign in with GitHub", bundle: .module), action: connect)
              .accessibilityIdentifier("settings-sign-in")
          }
        }
        if account != nil {
          Section(String(localized: "Writing", bundle: .module)) {
            Toggle(String(localized: "Autosave While Writing", bundle: .module), isOn: preference(.isAutoSaveEnabled, default: true))
              .accessibilityIdentifier("settings-autosave")
            Toggle(String(localized: "Check Spelling", bundle: .module), isOn: preference(.isSpellcheckEnabled, default: true))
              .accessibilityIdentifier("settings-spelling")
            Toggle(String(localized: "Show Front Matter", bundle: .module), isOn: preference(.showFrontmatter, default: false))
              .accessibilityIdentifier("settings-front-matter")
          }
          Section(String(localized: "Appearance", bundle: .module)) { appearance() }
        }
      }
      .disabled(isWorking)
      .interactiveDismissDisabled(isWorking)
      .navigationTitle(Text("Settings", bundle: .module))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .close) { dismiss() }
            .accessibilityLabel(Text("Close Settings", bundle: .module))
            .disabled(isWorking)
        }
      }
      .alert(
        Text("Sign Out?", bundle: .module),
        isPresented: $confirmingSignOut
      ) {
        Button(String(localized: "Sign Out", bundle: .module), role: .destructive, action: confirmSignOut)
        Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
      } message: {
        Text("Drafts for @\(account?.github.login ?? "") stay on this iPhone. Nothing is published.", bundle: .module)
      }
      .alert(
        errorTitle,
        isPresented: Binding(
          get: { saveError != nil }, set: { if !$0 { saveError = nil } })
      ) {
        Button(String(localized: "OK", bundle: .module)) { saveError = nil }
      } message: {
        Text(saveError ?? "")
      }
    }
  }

  private var isWorking: Bool { pendingPreference != nil || isSigningOut }

  private func confirmSignOut() {
    guard !isWorking else { return }
    isSigningOut = true
    saveError = nil
    errorTitle = String(localized: "Couldn't Sign Out", bundle: .module)
    Task {
      defer { isSigningOut = false }
      do {
        try await signOut()
        dismiss()
      } catch {
        saveError = error.localizedDescription
      }
    }
  }

  private func preference(_ key: BooleanPreference, default fallback: Bool) -> Binding<Bool> {
    Binding(
      get: {
        if let pendingPreference, pendingPreference.key == key { return pendingPreference.value }
        return account?.preferences.booleanValue(key, default: fallback) ?? fallback
      },
      set: { value in
        guard pendingPreference == nil else { return }
        pendingPreference = (key, value)
        saveError = nil
        errorTitle = String(localized: "Couldn't Confirm Setting", bundle: .module)
        Task {
          defer { pendingPreference = nil }
          do {
            try await savePreference(key, value)
          } catch {
            saveError = error.localizedDescription
          }
        }
      })
  }
}
#endif
