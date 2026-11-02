@testable import GistPadEditor
import GistPadInterface
import SwiftUI
import Testing
import UIKit
@testable import GistPad

@MainActor
@Suite(.serialized)
struct SourceKeyboardHostTests {
    @Test func restylingClearsRemovedBoldHeadingAndFenceAttributes() async throws {
        let fixture = try await SourceKeyboardFixture(
            source: "# A heading\n\nA **bold** word.\n\n```swift\nlet note = 1\n\nA later paragraph.\n",
            size: "large"
        )
        defer { fixture.close() }
        let session = fixture.session
        session.requestFocusAtEnd()
        try await fixture.settle("the removed styling caret")
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
                SourceEdit(range: range, expected: change.0, replacement: change.1),
                generation: session.generation
            )
            session.highlight()
            let expected = DocumentSession(documentID: "expected-style", text: expectedText)
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
        try await fixture.settle("the real keyboard and final caret")
        try fixture.expectKeyboardViewport()
        try fixture.expectVisibleCaret()

        var expected = source
        for input in ["\n", "One more thought", " stays in view", "."] {
            fixture.editor.insertText(input)
            expected += input
            try await fixture.settle("the final caret after native input")
            #expect(fixture.session.text.utf8.elementsEqual(expected.utf8))
            #expect(fixture.editor.selectedRange == NSRange(location: expected.utf16.count, length: 0))
            try fixture.expectKeyboardViewport()
            try fixture.expectVisibleCaret()
        }
    }

    @Test("Native end scrolling reveals the last line above the formatting capsule")
    func lastLineScrollReachability() async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large")
        defer { fixture.close() }
        fixture.editor.selectedRange = NSRange(location: 0, length: 0)
        try #require(fixture.editor.becomeFirstResponder())
        try await fixture.settle("the real keyboard at the start of the note")
        try fixture.expectKeyboardViewport()

        let manager = try #require(fixture.editor.textLayoutManager)
        let range = try #require(manager.textContentManager?.documentRange)
        manager.ensureLayout(for: range)
        fixture.editor.layoutIfNeeded()
        try await fixture.settle("the fully laid-out document before end scrolling")
        let maximum = fixture.editor.contentSize.height - fixture.editor.bounds.height
            + fixture.editor.adjustedContentInset.bottom
        try #require(maximum > fixture.editor.bounds.height)
        fixture.editor.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
        try await fixture.settle("native end scrolling")
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
        try await fixture.settle("the focused final caret before a deliberate scroll")
        try fixture.expectVisibleCaret()
        fixture.editor.delegate?.scrollViewWillBeginDragging?(fixture.editor)
        fixture.editor.setContentOffset(
            CGPoint(x: 0, y: fixture.editor.contentSize.height / 2), animated: false
        )
        try await fixture.settle("the deliberate keyboard-up reading position")
        let offset = fixture.editor.contentOffset
        let selection = fixture.editor.selectedRange
        for _ in 0..<3 {
            fixture.session.highlight()
            try await fixture.settle("a restyle at the deliberate reading position")
            #expect(abs(fixture.editor.contentOffset.y - offset.y) <= 1)
            #expect(fixture.editor.selectedRange == selection)
            #expect(fixture.editor.isFirstResponder)
            let caret = fixture.editor.caretRect(for: fixture.editor.endOfDocument)
            #expect(!fixture.editor.bounds.inset(
                by: fixture.editor.adjustedContentInset
            ).intersects(caret))
        }
        #expect(fixture.session.text.utf8.elementsEqual(Self.source.utf8))
        #expect(fixture.session.generation == 0)
    }

    @Test(arguments: [false, true])
    func compositionAndWritingToolsKeepTheirOwnScrolling(writingTools: Bool) async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large")
        defer { fixture.close() }
        fixture.session.requestFocusAtEnd()
        try await fixture.settle("the focused editor before system text interaction")
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

    @Test(
        "The formatting capsule centers over the note beside an open sidebar",
        .enabled("A sidebar sits beside the note only in a regular-width window") {
            await MainActor.run {
                UIApplication.shared.connectedScenes.contains {
                    ($0 as? UIWindowScene)?.traitCollection.horizontalSizeClass == .regular
                }
            }
        }
    )
    func capsuleCentersOverTheNote() async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: "large", sidebarFraction: 1 / 3)
        defer { fixture.close() }
        fixture.session.requestFocusAtEnd()
        try await fixture.settle("the real keyboard beside a sidebar")
        let accessory = try #require(fixture.editor.inputAccessoryView as? SourceAccessoryView)
        let note = fixture.editor.convert(fixture.editor.bounds, to: fixture.window)
        let capsule = accessory.glass.convert(accessory.glass.bounds, to: fixture.window)
        #expect(abs(capsule.midX - note.midX) <= 1)
        #expect(capsule.minX >= note.minX + 16 - 1)
        #expect(capsule.width <= 380)
    }

    private static let lastLine = "Last reachable line."
    private static let source = "# A reachable source page\n\n"
        + String(repeating: "A retained thought has enough room to keep unfolding.\n\n", count: 60)
        + lastLine
}

@MainActor
private final class SourceKeyboardFixture {
    let session: DocumentSession
    let window: UIWindow
    private let host: UIViewController
    private weak var previousKeyWindow: UIWindow?
    var editor: UITextView { session.textView }

    init(source: String, size: String, sidebarFraction: CGFloat = 0) async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        previousKeyWindow = scene.keyWindow
        let session = DocumentSession(documentID: "source-keyboard-\(size)", text: source)
        self.session = session
        let window = UIWindow(windowScene: scene)
        self.window = window
        let controller = SourceKeyboardHostingController(rootView:
            NavigationStack {
                NoteScreen(
                    document: .init(
                        title: "A reachable source page",
                        files: [.init(id: "README.md", filename: "README.md")],
                        selectedFileID: "README.md"
                    ),
                    mode: .constant(.source), saveState: .savedToGitHub
                ) {
                    MarkdownEditorView(session: session)
                } preview: {
                    Color.clear
                }
            }
            .padding(.leading, scene.coordinateSpace.bounds.width * sidebarFraction)
            .dynamicTypeSize(size == "large" ? .large : .accessibility3)
        )
        controller.traitOverrides.preferredContentSizeCategory =
            size == "large" ? .large : .accessibilityExtraExtraExtraLarge
        host = controller
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        var ready = false
        defer { if !ready { close() } }
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !controller.hasAppeared {
            guard ContinuousClock.now < deadline else {
                throw SourceKeyboardFailure.unsettled("native source fixture appearance")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.view.layoutIfNeeded()
        ready = true
    }

    func close() {
        editor.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    func settle(_ name: String) async throws {
        let clock = ContinuousClock()
        var lastSample: Sample?
        var stableSince = clock.now
        var stableSamples = 0
        for _ in 0..<300 {
            host.view.layoutIfNeeded()
            editor.layoutIfNeeded()
            let keyboardReady = editor.inputAccessoryView.map { accessory in
                editor.isFirstResponder && accessory.window != nil
                    && host.view.keyboardLayoutGuide.layoutFrame.height
                        > accessory.bounds.height + window.safeAreaInsets.bottom + 1
                    && viewportMeetsAccessory(accessory)
            } ?? false
            if editor.window === window, keyboardReady {
                let sample = sample()
                if sample == lastSample {
                    stableSamples += 1
                } else {
                    lastSample = sample
                    stableSince = clock.now
                    stableSamples = 1
                }
                if stableSamples >= 20, clock.now - stableSince >= .milliseconds(350) {
                    return
                }
            } else {
                lastSample = nil
                stableSamples = 0
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SourceKeyboardFailure.unsettled(name)
    }

    /// The editor's bottom inset can lag a keyboard resize, so readiness also requires it to match the accessory.
    private func viewportMeetsAccessory(_ accessory: UIView) -> Bool {
        let accessoryTop = accessory.convert(accessory.bounds, to: window).minY
        let viewport = editor.convert(editor.bounds.inset(by: editor.adjustedContentInset), to: window)
        return abs(viewport.maxY - accessoryTop) <= 1
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

    private func sample() -> Sample {
        let caret = editor.selectedTextRange.map {
            editor.convert(editor.caretRect(for: $0.end), to: window)
        } ?? .null
        return Sample(
            editorFrame: editor.convert(editor.bounds, to: window),
            contentSize: editor.contentSize, offset: editor.contentOffset,
            insets: editor.adjustedContentInset,
            accessory: editor.inputAccessoryView.map { $0.convert($0.bounds, to: window) } ?? .null,
            keyboard: host.view.keyboardLayoutGuide.layoutFrame, caret: caret
        )
    }

    private func findNavigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        return view.subviews.lazy.compactMap { self.findNavigationBar(in: $0) }.first
    }

    private struct Sample: Equatable {
        let editorFrame: CGRect
        let contentSize: CGSize
        let offset: CGPoint
        let insets: UIEdgeInsets
        let accessory: CGRect
        let keyboard: CGRect
        let caret: CGRect
    }
}

@MainActor
private final class SourceKeyboardHostingController<Content: View>: UIHostingController<Content> {
    private(set) var hasAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }
}

private enum SourceKeyboardFailure: Error {
    case unsettled(String)
}
