@testable import Editor
import Screens
import SwiftUI
import Testing
import UIKit
@testable import GistPad

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SourceKeyboardHostTests {
    @Test func restylingClearsRemovedBoldHeadingAndFenceAttributes() async throws {
        let fixture = try await SourceKeyboardFixture(
            source: "# A heading\n\nA **bold** word.\n\n```swift\nlet note = 1\n\nA later paragraph.\n",
            size: "large"
        )
        defer { fixture.close() }
        let session = fixture.session
        session.requestFocusAtEnd()
        await fixture.layOutUnderKeyboard()
        let changes = [
            ("**bold**", "bold"),
            ("let note = 1\n\n", "let note = 1\n```\n\n"),
            ("let note = 1\n```\n\n", "let note = 1\n\n"),
            ("# A heading", "A heading"),
        ]
        for (index, change) in changes.enumerated() {
            let range = (session.text as NSString).range(of: change.0)
            try #require(range.location != NSNotFound)
            let expectedText = (session.text as NSString).replacingCharacters(
                in: range, with: change.1
            )
            try session.apply(
                Edit(range: range, expected: change.0, replacement: change.1),
                generation: session.generation
            )
            session.highlight()
            let expected = MarkdownEditor(text: expectedText)
            expected.textView.traitOverrides.preferredContentSizeCategory =
                session.textView.traitCollection.preferredContentSizeCategory
            expected.highlight()
            #expect(
                session.textView.textStorage.isEqual(to: expected.textView.textStorage),
                "Styling must match a fresh document after changing \(change.0) to \(change.1)."
            )
            #expect(session.text.utf8.elementsEqual(expectedText.utf8))
            #expect(session.generation == UInt64(index + 1))
        }
    }

    @Test("Typing keeps the final caret above the real formatting capsule", arguments: ["large", "ax3"])
    func finalLineTyping(size: String) async throws {
        let source = Self.source
        let fixture = try await SourceKeyboardFixture(source: source, size: size)
        defer { fixture.close() }
        fixture.session.requestFocusAtEnd()
        await fixture.layOutUnderKeyboard()
        try fixture.expectKeyboardViewport()
        try fixture.expectVisibleCaret()

        var expected = source
        for input in ["\n", "One more thought", " stays in view", "."] {
            fixture.editor.insertText(input)
            expected += input
            await fixture.layOutUnderKeyboard()
            #expect(fixture.session.text.utf8.elementsEqual(expected.utf8))
            #expect(fixture.editor.selectedRange == NSRange(location: expected.utf16.count, length: 0))
            try fixture.expectKeyboardViewport()
            try fixture.expectVisibleCaret()
        }
    }

    @Test("The bar follows the source, so it minimizes and draws its edge as the source scrolls")
    func barFollowsTheSource() async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large")
        defer { fixture.close() }
        var responder: UIResponder? = fixture.editor
        while let current = responder, !(current is UINavigationController) {
            responder = current.next
        }
        let navigation = try #require(responder as? UINavigationController)
        #expect(navigation.topViewController?.contentScrollView(for: .top) === fixture.editor)
    }

    @Test("Native end scrolling reveals the last line above the formatting capsule")
    func lastLineScrollReachability() async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large")
        defer { fixture.close() }
        fixture.editor.selectedRange = NSRange(location: 0, length: 0)
        try #require(fixture.editor.becomeFirstResponder())
        await fixture.layOutUnderKeyboard()
        try fixture.expectKeyboardViewport()

        let manager = try #require(fixture.editor.textLayoutManager)
        let range = try #require(manager.textContentManager?.documentRange)
        manager.ensureLayout(for: range)
        fixture.editor.layoutIfNeeded()
        await fixture.layOutUnderKeyboard()
        let maximum = fixture.editor.contentSize.height - fixture.editor.bounds.height
            + fixture.editor.adjustedContentInset.bottom
        try #require(maximum > fixture.editor.bounds.height)
        fixture.editor.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
        await fixture.layOutUnderKeyboard()
        let settledMaximum = fixture.editor.contentSize.height - fixture.editor.bounds.height
            + fixture.editor.adjustedContentInset.bottom
        #expect(abs(fixture.editor.contentOffset.y - settledMaximum) <= 1)
        #expect(fixture.editor.selectedRange == NSRange(location: 0, length: 0))
        #expect(fixture.session.text.utf8.elementsEqual(Self.source.utf8))
        #expect(fixture.session.generation == 0)

        let lastLine = (Self.source as NSString).range(of: Self.lastLine, options: .backwards)
        try #require(lastLine.location != NSNotFound)
        let start = try #require(fixture.editor.position(
            from: fixture.editor.beginningOfDocument, offset: lastLine.location
        ))
        let end = fixture.editor.endOfDocument
        let textRange = try #require(fixture.editor.textRange(from: start, to: end))
        let rects = fixture.editor.selectionRects(for: textRange).map(\.rect).filter { $0.width > 0 }
        try #require(!rects.isEmpty)
        for rect in rects {
            try fixture.expectUnobscured(fixture.editor.convert(rect, to: fixture.window))
        }
        try fixture.expectUnobscured(
            fixture.editor.convert(fixture.editor.caretRect(for: end), to: fixture.window)
        )
        try fixture.expectKeyboardViewport()
    }

    @Test("Restyling never pulls a deliberate keyboard-up scroll back to the caret")
    func deliberateScrollAwaySurvivesRestyling() async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large")
        defer { fixture.close() }
        fixture.session.requestFocusAtEnd()
        await fixture.layOutUnderKeyboard()
        try fixture.expectVisibleCaret()
        var keyboardInsets = fixture.editor.adjustedContentInset
        var caretIsVisible = true
        for _ in 0..<2 where caretIsVisible {
            fixture.editor.delegate?.scrollViewWillBeginDragging?(fixture.editor)
            fixture.editor.setContentOffset(
                CGPoint(x: 0, y: fixture.editor.contentSize.height / 4), animated: false
            )
            await fixture.layOutUnderKeyboard()
            caretIsVisible = fixture.editor.bounds.inset(by: fixture.editor.adjustedContentInset)
                .intersects(fixture.editor.caretRect(for: fixture.editor.endOfDocument))
            // A late keyboard resize reveals the caret by design, so scroll away once more after one.
            if caretIsVisible {
                try #require(fixture.editor.adjustedContentInset != keyboardInsets)
                keyboardInsets = fixture.editor.adjustedContentInset
            }
        }
        try #require(!caretIsVisible)
        let offset = fixture.editor.contentOffset
        let selection = fixture.editor.selectedRange
        for _ in 0..<3 {
            fixture.session.highlight()
            await fixture.layOutUnderKeyboard()
            #expect(abs(fixture.editor.contentOffset.y - offset.y) <= 1)
            #expect(fixture.editor.selectedRange == selection)
            #expect(fixture.editor.isFirstResponder)
            let caret = fixture.editor.caretRect(for: fixture.editor.endOfDocument)
            let viewport = fixture.editor.bounds.inset(by: fixture.editor.adjustedContentInset)
            #expect(!viewport.intersects(caret))
        }
        #expect(fixture.session.text.utf8.elementsEqual(Self.source.utf8))
        #expect(fixture.session.generation == 0)
    }

    @Test(arguments: [false, true])
    func compositionAndWritingToolsKeepTheirOwnScrolling(writingTools: Bool) async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large")
        defer { fixture.close() }
        fixture.session.requestFocusAtEnd()
        await fixture.layOutUnderKeyboard()
        if writingTools {
            fixture.session.textViewWritingToolsWillBegin(fixture.editor)
        } else {
            fixture.editor.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0))
            try #require(fixture.editor.markedTextRange != nil)
        }
        defer {
            if writingTools {
                fixture.session.textViewWritingToolsDidEnd(fixture.editor)
            } else {
                fixture.editor.unmarkText()
            }
        }
        fixture.editor.setContentOffset(
            CGPoint(x: 0, y: fixture.editor.contentSize.height / 2), animated: false
        )
        let offset = fixture.editor.contentOffset
        let selection = fixture.editor.selectedRange
        let source = fixture.editor.text
        let generation = fixture.session.generation
        for _ in 0..<3 {
            fixture.session.highlight()
            fixture.editor.setNeedsLayout()
            fixture.editor.layoutIfNeeded()
            #expect(fixture.editor.contentOffset == offset)
            #expect(fixture.editor.selectedRange == selection)
            #expect(fixture.editor.text == source)
            #expect(fixture.session.generation == generation)
            #expect(fixture.editor.isFirstResponder)
            #expect((fixture.editor.markedTextRange != nil) == !writingTools)
        }
    }

    private static let lastLine = "Last reachable line."
    private static let source = "# A reachable source page\n\n"
        + String(repeating: "A retained thought has enough room to keep unfolding.\n\n", count: 60)
        + lastLine
}

private final class SourceKeyboardFixture {
    let session: MarkdownEditor
    let window: UIWindow
    private let host: UIViewController
    private weak var previousKeyWindow: UIWindow?
    var editor: UITextView { session.textView }

    init(source: String, size: String) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        previousKeyWindow = scene.keyWindow
        let session = MarkdownEditor(text: source)
        self.session = session
        let window = UIWindow(windowScene: scene)
        self.window = window
        let controller = SourceKeyboardHostingController(rootView:
            NavigationStack {
                GistScreen(
                    gist: .init(
                        title: "A reachable source page",
                        filenames: ["README.md"], filename: "README.md"
                    ),
                    mode: .constant(.edit), status: .published
                ) {
                    MarkdownEditorView(editor: session)
                } preview: {
                    Color.clear
                }
            }
            .dynamicTypeSize(size == "large" ? .large : .accessibility3)
        )
        controller.traitOverrides.preferredContentSizeCategory =
            size == "large" ? .large : .accessibilityExtraExtraExtraLarge
        host = controller
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        await completion { done in
            controller.didAppear = done
            window.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
    }

    func close() {
        editor.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    /// Lays out the page once the keyboard is up over it. The first keyboard in a fresh window can
    /// take several seconds while the suite runs.
    func layOutUnderKeyboard() async {
        await keyboard(visible: true, over: host.view)
    }

    func expectKeyboardViewport() throws {
        let accessory = try #require(editor.inputAccessoryView)
        try #require(accessory.window != nil)
        let accessoryFrame = accessory.convert(accessory.bounds, to: window)
        let editorFrame = editor.convert(editor.bounds, to: window)
        #expect(accessoryFrame.height > 0)
        #expect(editorFrame.maxY >= accessoryFrame.minY - 1,
                "Source must reach the actual formatting accessory.")
        #expect(editorFrame.maxY >= accessoryFrame.maxY - 1,
                "Source must flow beneath the formatting accessory with no hard edge.")
        let viewport = editor.convert(editor.bounds.inset(by: editor.adjustedContentInset), to: window)
        #expect(abs(viewport.maxY - accessoryFrame.minY) <= 1,
                "The unobscured writing region must stop above the actual capsule.")
    }

    func expectVisibleCaret() throws {
        let selection = try #require(editor.selectedTextRange)
        let caret = editor.convert(editor.caretRect(for: selection.end), to: window)
        try expectUnobscured(caret)
    }

    func expectUnobscured(_ rect: CGRect) throws {
        let accessory = try #require(editor.inputAccessoryView)
        let navigationBar = try #require(findNavigationBar(in: host.view))
        let top = navigationBar.convert(navigationBar.bounds, to: window).maxY
        let bottom = accessory.convert(accessory.bounds, to: window).minY
        #expect(rect.height > 0 && rect.minY.isFinite && rect.maxY.isFinite)
        #expect(rect.minY >= top - 1, "The actual glyph/caret rectangle must clear navigation.")
        #expect(rect.maxY <= bottom + 1, "The actual glyph/caret rectangle must clear the capsule.")
    }

    private func findNavigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        return view.subviews.lazy.compactMap { self.findNavigationBar(in: $0) }.first
    }
}

private final class SourceKeyboardHostingController<Content: View>: UIHostingController<Content> {
    var didAppear = {}

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear()
    }
}
