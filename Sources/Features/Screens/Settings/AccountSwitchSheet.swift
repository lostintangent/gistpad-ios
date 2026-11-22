#if os(iOS)
import SwiftUI

public struct AccountSwitchSheet: View {
  let current: String
  let replacement: String
  let switchAccount: @MainActor () async throws -> Void
  let keepCurrent: @MainActor () -> Void
  @State private var isWorking = false
  @State private var error: String?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    current: String, replacement: String,
    switchAccount: @escaping @MainActor () async throws -> Void,
    keepCurrent: @escaping @MainActor () -> Void
  ) {
    self.current = current
    self.replacement = replacement
    self.switchAccount = switchAccount
    self.keepCurrent = keepCurrent
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent(String(localized: "Current", bundle: .module), value: "@\(current)")
          LabeledContent(String(localized: "New account", bundle: .module), value: "@\(replacement)")
        } footer: {
          Text("Your drafts stay on this iPhone with their original account. Switching never publishes them.", bundle: .module)
        }
        Section {
          Button(String(localized: "Switch to @\(replacement)", bundle: .module), action: confirm)
            .accessibilityIdentifier("account-switch-confirm")
        } footer: {
          Text("Reconnect the original account to return to its drafts.", bundle: .module)
        }
        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.circle")
          }
        }
      }
      .navigationTitle(Text("Switch Account", bundle: .module))
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

  private func confirm() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        try await switchAccount()
        error = nil
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
#endif
