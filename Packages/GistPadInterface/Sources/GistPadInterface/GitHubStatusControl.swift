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
    public let isRecovering: Bool
    public let canRecover: Bool
    public let retryAfter: Date?

    public init(
        heading: String, message: String, recoveryTitle: String, detail: String? = nil,
        isRecovering: Bool = false, canRecover: Bool = true, retryAfter: Date? = nil
    ) {
        self.heading = heading
        self.message = message
        self.recoveryTitle = recoveryTitle
        self.detail = detail
        self.isRecovering = isRecovering
        self.canRecover = canRecover
        self.retryAfter = retryAfter
    }
}

#if os(iOS)
import OSLog
import SwiftUI
import UIKit

private struct GitHubStatusVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    var isGitHubStatusVisible: Bool {
        get { self[GitHubStatusVisibilityKey.self] }
        set { self[GitHubStatusVisibilityKey.self] = newValue }
    }
}

public extension View {
    func gitHubStatusKeyboardPolicy() -> some View {
        modifier(GitHubStatusKeyboardPolicy())
    }
}

private struct GitHubStatusKeyboardPolicy: ViewModifier {
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .environment(\.isGitHubStatusVisible, isVisible)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isVisible = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                isVisible = true
            }
    }
}

public struct GitHubStatusControl: View {
    private let state: GitHubStatusState
    private let recover: @MainActor () -> Void
    @State private var spinnerOperation: String?
    @State private var showingDetails = false
    @State private var retryReadyFor: Date?
    @State private var explanationHeight: CGFloat = 0
    @State private var explanationTopInset: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        .tint(.secondary)
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
                .tint(.primary)
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
            do {
                try await Task.sleep(for: .milliseconds(350))
                spinnerOperation = operation
            } catch is CancellationError {
                return
            } catch {
                Logger(subsystem: "dev.gistpad.GistPad", category: "Status")
                    .error("The status progress delay failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        .onChange(of: state) { _, state in
            if case .idle = state { showingDetails = false }
        }
    }

    private var checkingOperation: String? {
        if case .checking(let operation) = state { operation } else { nil }
    }

    private func explanation(_ problem: GitHubStatusProblem) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: problem.heading)
                        .font(.headline)
                    Text(verbatim: problem.message)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = problem.detail {
                        Text(verbatim: detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let retryAfter = problem.retryAfter, !deadlineReached(for: problem) {
                        Text(
                            "Try again after \(retryAfter, format: Date.FormatStyle(date: .abbreviated, time: .shortened)).",
                            bundle: .module
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button(action: recover) {
                            Text(verbatim: problem.recoveryTitle)
                                .foregroundStyle(Color(uiColor: .systemBackground))
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .tint(Color(uiColor: .label))
                        .frame(minHeight: 44)
                        .disabled(
                            problem.isRecovering || !problem.canRecover
                                || !deadlineReached(for: problem))
                        .accessibilityIdentifier("github-status-recover")
                        .captureFrame("github-status-recover")
                        if problem.isRecovering {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.secondary)
                                .accessibilityLabel(Text("Trying again", bundle: .module))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    explanationHeight = $0
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
                explanationTopInset = inset
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle(Text("GitHub status", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", bundle: .module), systemImage: "xmark") {
                        showingDetails = false
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("github-status-close")
                }
            }
        }
        .frame(idealWidth: 360)
        .presentationCompactAdaptation(.sheet)
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize ? [.large] : [
                .height(explanationHeight > 0 ? explanationHeight + explanationTopInset : 350),
                .large
            ])
        .presentationDragIndicator(.visible)
        .task(id: problem.retryAfter) {
            retryReadyFor = nil
            guard let deadline = problem.retryAfter else { return }
            do {
                let delay = deadline.timeIntervalSinceNow
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                retryReadyFor = deadline
            } catch is CancellationError {
                return
            } catch {
                Logger(subsystem: "dev.gistpad.GistPad", category: "Status")
                    .error("The recovery deadline delay failed: \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    private func deadlineReached(for problem: GitHubStatusProblem) -> Bool {
        guard let deadline = problem.retryAfter else { return true }
        return retryReadyFor == deadline || deadline <= .now
    }
}

#endif
