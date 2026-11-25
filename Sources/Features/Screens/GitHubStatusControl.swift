import Foundation
import Store

/// Where the list or the open note stands with reading GitHub.
public enum GitHubStatus: Equatable, Sendable {
    case idle
    case checking
    case failed(Failure)

    /// The failure, when there is one.
    public var failure: Failure? {
        if case .failed(let failure) = self { failure } else { nil }
    }
}

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

public struct GitHubStatusControl: View {
    private let status: GitHubStatus
    private let recover: @MainActor () -> Void
    @State private var showsSpinner = false
    @State private var showingDetails = false

    public init(status: GitHubStatus, recover: @escaping @MainActor () -> Void) {
        self.status = status
        self.recover = recover
    }

    public var body: some View {
        ZStack {
            switch status {
            case .idle:
                EmptyView()
            case .checking:
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Checking GitHub for changes", bundle: .module))
                        .accessibilityIdentifier("github-status-checking")
                }
            case .failed(let failure):
                Button(
                    String(localized: "GitHub needs attention", bundle: .module),
                    systemImage: "exclamationmark"
                ) {
                    showingDetails = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityValue(failure.message)
                .accessibilityHint(Text("Shows details and recovery actions", bundle: .module))
                .accessibilityIdentifier("github-status-attention")
                .popover(isPresented: $showingDetails) {
                    explanation(failure)
                }
            }
        }
        .task(id: status == .checking) {
            showsSpinner = false
            guard status == .checking else { return }
            try? await Task.sleep(for: .milliseconds(350))
            showsSpinner = !Task.isCancelled
        }
        .onChange(of: status) { _, status in
            if case .idle = status { showingDetails = false }
        }
    }

    private func explanation(_ failure: Failure) -> some View {
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
