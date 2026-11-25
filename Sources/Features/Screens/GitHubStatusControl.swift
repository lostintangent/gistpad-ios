import Foundation
import Store

extension Failure.Action {
    /// The button that offers this fix.
    public var title: String {
        switch self {
        case .tryAgain: String(localized: "Try Again", bundle: .module)
        case .reconnect: String(localized: "Reconnect GitHub", bundle: .module)
        }
    }
}

#if os(iOS)
import SwiftUI

/// The `!` that says the list or the open note couldn't read GitHub, and explains why.
public struct GitHubStatusControl: View {
    private let failure: Failure
    private let recover: @MainActor () -> Void
    @State private var showingDetails = false

    public init(failure: Failure, recover: @escaping @MainActor () -> Void) {
        self.failure = failure
        self.recover = recover
    }

    public var body: some View {
        Button(String(localized: "GitHub needs attention", bundle: .module), systemImage: "exclamationmark") {
            showingDetails = true
        }
        .labelStyle(.iconOnly)
        .accessibilityValue(failure.message)
        .accessibilityHint(Text("Shows details and recovery actions", bundle: .module))
        .accessibilityIdentifier("github-status-attention")
        .popover(isPresented: $showingDetails) {
            explanation
        }
    }

    private var explanation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Couldn’t Check for Changes", bundle: .module)
                    .font(.headline)
                Text(verbatim: failure.message)
                if let action = failure.action {
                    Button(action.title, action: recover)
                        .accessibilityIdentifier("github-status-recover")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 360)
        .presentationCompactAdaptation(.popover)
    }
}

#endif
