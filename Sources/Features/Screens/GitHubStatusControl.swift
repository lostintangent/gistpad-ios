import Foundation
import Store

public enum GitHubStatusState: Equatable, Sendable {
    case idle
    case checking(operation: String)
    /// `heading` names what didn't happen, and `detail` what's still safe.
    case problem(GitHubProblem, heading: String, detail: String? = nil)

    /// The problem, when there is one.
    public var problem: GitHubProblem? {
        if case .problem(let problem, _, _) = self { problem } else { nil }
    }
}

#if os(iOS)
import SwiftUI

public struct GitHubStatusControl: View {
    private let state: GitHubStatusState
    private let recover: @MainActor () -> Void
    @State private var spinnerOperation: String?
    @State private var showingDetails = false

    public init(state: GitHubStatusState, recover: @escaping @MainActor () -> Void) {
        self.state = state
        self.recover = recover
    }

    public var body: some View {
        ZStack {
            switch state {
            case .idle:
                EmptyView()
            case .checking(let operation):
                if spinnerOperation == operation {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(operation)
                        .accessibilityIdentifier("github-status-checking")
                }
            case .problem(let problem, let heading, let detail):
                Button(
                    String(localized: "GitHub needs attention", bundle: .module),
                    systemImage: "exclamationmark"
                ) {
                    showingDetails = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityValue(message(problem))
                .accessibilityHint(Text("Shows details and recovery actions", bundle: .module))
                .accessibilityIdentifier("github-status-attention")
                .popover(isPresented: $showingDetails) {
                    explanation(problem, heading: heading, detail: detail)
                }
            }
        }
        .task(id: checkingOperation) {
            spinnerOperation = nil
            guard let operation = checkingOperation else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            spinnerOperation = operation
        }
        .onChange(of: state) { _, state in
            if case .idle = state { showingDetails = false }
        }
    }

    private var checkingOperation: String? {
        if case .checking(let operation) = state { operation } else { nil }
    }

    private func message(_ problem: GitHubProblem) -> String {
        switch problem {
        case .offline: String(localized: "GitHub couldn't be reached.", bundle: .module)
        case .reconnect: String(localized: "Reconnect GitHub to check for changes.", bundle: .module)
        case .rejected: String(localized: "GitHub declined the request.", bundle: .module)
        }
    }

    private func explanation(_ problem: GitHubProblem, heading: String, detail: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: heading)
                    .font(.headline)
                Text(verbatim: message(problem))
                if let detail {
                    Text(verbatim: detail)
                        .foregroundStyle(.secondary)
                }
                Button(
                    problem == .reconnect
                        ? String(localized: "Reconnect GitHub", bundle: .module)
                        : String(localized: "Try Again", bundle: .module),
                    action: recover
                )
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("github-status-recover")
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
