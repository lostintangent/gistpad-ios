@testable import Editor
import Screens
import Observation
import Store
import SwiftUI
import Testing
import UIKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GitHubStatusHostTests {
    @Test func statusUpdatesPreserveAScrolledEditorsSourceSelectionAndViewport() async throws {
        let source = (1...180).map {
            "Paragraph \($0) leaves enough room for a useful thought and a retained writing position."
        }.joined(separator: "\n\n")
        let host = try StatusHost(source: source)
        defer { host.close() }
        let session = try #require(host.session)
        let editor = session.textView
        var geometry: [String] = []
        func sourceAtViewportTop() -> Int? {
            let point = CGPoint(
                x: editor.textContainerInset.left + editor.textContainer.lineFragmentPadding,
                y: editor.bounds.minY + editor.adjustedContentInset.top + 1)
            guard let position = editor.closestPosition(to: point) else { return nil }
            return editor.offset(from: editor.beginningOfDocument, to: position)
        }
        func capture(_ stage: String) {
            let viewportSource = sourceAtViewportTop()
            let caret = editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .null
            geometry.append(
                """
                \(stage): offset \(editor.contentOffset), bounds \(editor.bounds), content \(editor.contentSize), \
                insets \(editor.contentInset), adjusted \(editor.adjustedContentInset), \
                textContainer \(editor.textContainer.size), caret \(caret), \
                windowCaret \(editor.convert(caret, to: host.window)), viewportSource \(String(describing: viewportSource)), \
                selected \(editor.selectedRange), font \(editor.font?.pointSize ?? 0), \
                focus \(editor.isFirstResponder), keyboard \(host.view.keyboardLayoutGuide.layoutFrame.height), \
                presented \(host.presented != nil)
                """)
        }
        defer { Attachment.record(geometry.joined(separator: "\n"), named: "status-source-viewport.txt") }
        try #require(editor.becomeFirstResponder())
        await keyboard(visible: true, over: host.view)
        let selection = (source as NSString).range(of: "Paragraph 140")
        func writingPosition() -> CGRect {
            guard let caret = editor.selectedTextRange?.end else { return .null }
            return editor.convert(editor.caretRect(for: caret), to: host.window)
        }
        editor.selectedRange = selection
        editor.scrollRangeToVisible(selection)
        host.window.layoutIfNeeded()
        let viewportSource = try #require(sourceAtViewportTop())
        let scrolledPosition = writingPosition()
        let identity = session.id
        let canUndo = editor.undoManager?.canUndo
        capture("scrolled")
        let generation = session.generation
        let states: [(String, GitHubStatus)] = [
            ("attention", problem()),
            ("checking", .checking),
            ("unresolved", problem()),
            ("idle", .idle),
        ]
        for (stage, state) in states {
            host.model.state = state
            await until { host.model.renderedState == state }
            host.window.layoutIfNeeded()
            capture(stage)
            #expect(host.showsStatus == (state != .idle))
            #expect(session.id == identity)
            #expect(editor.selectedRange == selection)
            #expect(session.generation == generation)
            #expect(session.document.text.utf8.elementsEqual(source.utf8))
            #expect(editor.text.utf8.elementsEqual(source.utf8))
            #expect(editor.undoManager?.canUndo == canUndo)
            #expect(editor.isFirstResponder)
            #expect(sourceAtViewportTop() == viewportSource)
            #expect(abs(writingPosition().minY - scrolledPosition.minY) <= 1)
            #expect(abs(writingPosition().minX - scrolledPosition.minX) <= 1)
        }
        #expect(host.model.recoveries == 0)
    }

    private func problem() -> GitHubStatus {
        .failed(Failure("GitHub couldn’t be reached.", action: .tryAgain))
    }
}

@Observable
private final class StatusModel {
    var state: GitHubStatus = .idle
    var recoveries = 0
    var renderedState: GitHubStatus = .idle

    func recover() { recoveries += 1 }
}

private struct StatusFixture: View {
    @Bindable var model: StatusModel
    var session: MarkdownEditor?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    MarkdownEditorView(editor: session)
                } else {
                    Text("A real page remains in place.")
                }
            }
                .navigationTitle("A note")
                .toolbar {
                    if model.state != .idle {
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            GitHubStatusControl(status: model.state, recover: model.recover)
                        }
                    }
                }
                .onChange(of: model.state) { _, state in model.renderedState = state }
        }
    }
}

private final class StatusHost {
    let model = StatusModel()
    let window: UIWindow
    let view: UIView
    let session: MarkdownEditor?
    private let previous: UIWindow?

    init(source: String) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        session = MarkdownEditor(text: source)
        window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: StatusFixture(model: model, session: session).accent(savedHex: "#FACC15"))
        view = controller.view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    var presented: UIViewController? { window.rootViewController?.presentedViewController }

    /// Whether the bottom bar is up to show the status control.
    var showsStatus: Bool {
        func navigation(_ controller: UIViewController) -> UINavigationController? {
            controller as? UINavigationController ?? controller.children.lazy.compactMap(navigation).first
        }
        return window.rootViewController.flatMap(navigation).map { !$0.isToolbarHidden } ?? false
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
}
