import Screens
import SwiftUI

struct AccountSwitchSheet: View {
  let current: String
  let replacement: String
  let switchAccount: @MainActor () async throws -> Void
  let keepCurrent: @MainActor () -> Void
  @State private var isWorking = false
  @State private var error: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Current", value: "@\(current)")
          LabeledContent("New account", value: "@\(replacement)")
        } footer: {
          Text("Your drafts stay on this iPhone with their original account. Switching never publishes them.")
        }
        Section {
          Button("Switch to @\(replacement)") {
            work { try await switchAccount() }
          }
          .accessibilityIdentifier("account-switch-confirm")
        } footer: {
          Text("Reconnect the original account to return to its drafts.")
        }
        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.circle")
          }
        }
      }
      .navigationTitle("Switch Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel, action: keepCurrent)
        }
      }
      .disabled(isWorking)
      .interactiveDismissDisabled(isWorking)
      .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }
  }

  private func work(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        try await operation()
        error = nil
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
