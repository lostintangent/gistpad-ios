import Foundation

public enum GitHubStatusState: Equatable, Sendable {
    case idle
    case checking(operation: String)
    case problem(GitHubStatusProblem)
}

public struct GitHubStatusProblem: Equatable, Sendable {
    public let heading: String
    public let message: String
    public let recoveryTitle: String
    public let detail: String?

    public init(heading: String, message: String, recoveryTitle: String, detail: String? = nil) {
        self.heading = heading
        self.message = message
        self.recoveryTitle = recoveryTitle
        self.detail = detail
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
            case .problem(let problem):
                Button(
                    String(localized: "GitHub needs attention", bundle: .module),
                    systemImage: "exclamationmark"
                ) {
                    showingDetails = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityValue(problem.message)
                .accessibilityHint(Text("Shows details and recovery actions", bundle: .module))
                .accessibilityIdentifier("github-status-attention")
                .popover(isPresented: $showingDetails) {
                    explanation(problem)
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

    private func explanation(_ problem: GitHubStatusProblem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: problem.heading)
                    .font(.headline)
                Text(verbatim: problem.message)
                if let detail = problem.detail {
                    Text(verbatim: detail)
                        .foregroundStyle(.secondary)
                }
                Button(action: recover) {
                    Text(verbatim: problem.recoveryTitle)
                }
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
