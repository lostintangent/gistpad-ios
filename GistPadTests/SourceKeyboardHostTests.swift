import GistPadEditor
import GistPadInterface
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SourceKeyboardHostTests {
    @Test("Typing keeps the final caret above the real formatting capsule", arguments: ["large", "ax3"])
    func finalLineTyping(size: String) async throws {
        let source = Self.source
        let fixture = try await SourceKeyboardFixture(source: source, size: size)
        defer { fixture.close() }
        let identity = ObjectIdentifier(fixture.editor)
        fixture.session.requestFocusAtEnd()
        try await fixture.settle("the real keyboard and final caret")
        try fixture.expectKeyboardViewport()
        try fixture.expectVisibleCaret()
        try await fixture.captureCheckpoint(named: "final-caret-\(size)-focused")

        var expected = source
        for (index, input) in ["\n", "One more thought", " stays in view", "."].enumerated() {
            fixture.editor.insertText(input)
            expected += input
            try await fixture.settle("the final caret after native input")
            #expect(fixture.session.text.utf8.elementsEqual(expected.utf8))
            #expect(fixture.editor.selectedRange == NSRange(location: expected.utf16.count, length: 0))
            #expect(ObjectIdentifier(fixture.editor) == identity)
            try fixture.expectKeyboardViewport()
            try fixture.expectVisibleCaret()
            try await fixture.captureCheckpoint(named: "final-caret-\(size)-input-\(index)")
        }
        fixture.recordGeometry(named: "final-line-typing-\(size)")
    }

    @Test("Native end scrolling reveals the last line above the formatting capsule", arguments: ["large", "ax3"])
    func lastLineScrollReachability(size: String) async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: size)
        defer { fixture.close() }
        fixture.editor.selectedRange = NSRange(location: 0, length: 0)
        try #require(fixture.editor.becomeFirstResponder())
        try await fixture.settle("the real keyboard at the start of the note")
        try fixture.expectKeyboardViewport()

        let manager = try #require(fixture.editor.textLayoutManager)
        let range = try #require(manager.textContentManager?.documentRange)
        manager.ensureLayout(for: range)
        fixture.editor.layoutIfNeeded()
        let insets = fixture.editor.adjustedContentInset
        let maximum = fixture.editor.contentSize.height - fixture.editor.bounds.height + insets.bottom
        try #require(maximum > fixture.editor.bounds.height)
        fixture.editor.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
        try await fixture.settle("native end scrolling")
        #expect(abs(fixture.editor.contentOffset.y - maximum) <= 1)
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
        fixture.recordGeometry(named: "last-line-scroll-\(size)")
    }

    @Test("Restyling never pulls a deliberate keyboard-up scroll back to the caret", arguments: ["large", "ax3"])
    func deliberateScrollAwaySurvivesRestyling(size: String) async throws {
        let fixture = try await SourceKeyboardFixture(source: Self.source, size: size)
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
        fixture.recordGeometry(named: "manual-scroll-\(size)")
        try await fixture.captureCheckpoint(named: "manual-scroll-\(size)")
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

    init(source: String, size: String) async throws {
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
                    mode: .constant(.source), saveState: .inMemoryFixture
                ) {
                    MarkdownEditorView(session: session)
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
            if editor.window === window, editor.isFirstResponder,
               let accessory = editor.inputAccessoryView, accessory.window != nil,
               host.view.keyboardLayoutGuide.layoutFrame.height
                   > accessory.bounds.height + window.safeAreaInsets.bottom + 1 {
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
        recordGeometry(named: "unsettled-\(name)")
        throw SourceKeyboardFailure.unsettled(name)
    }

    func expectKeyboardViewport() throws {
        let accessory = try #require(editor.inputAccessoryView)
        try #require(accessory.window != nil)
        let accessoryFrame = accessory.convert(accessory.bounds, to: window)
        let editorFrame = editor.convert(editor.bounds, to: window)
        #expect(accessoryFrame.height > 0)
        #expect(editorFrame.maxY >= accessoryFrame.minY - 1,
                "Source must reach the actual formatting accessory.")
        #expect(editorFrame.maxY <= accessoryFrame.maxY + 1,
                "Source must never extend behind the system keys.")
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

    func recordGeometry(named name: String) {
        let geometry = """
            sample: \(sample())
            nativeSafeArea: \(editor.safeAreaInsets)
            containerBounds: \(String(describing: editor.superview?.bounds))
            containerKeyboardGuide: \(String(describing: editor.superview?.keyboardLayoutGuide.layoutFrame))
            keyboardGuide: \(host.view.keyboardLayoutGuide.layoutFrame)
            textCategory: \(editor.traitCollection.preferredContentSizeCategory.rawValue)
            selection: \(editor.selectedRange)
            """
        print("\(name): \(geometry)")
        Attachment.record(geometry, named: "\(name).txt")
    }

    func captureCheckpoint(named name: String) async throws {
        guard let run = ProcessInfo.processInfo.environment["GISTPAD_CARET_CAPTURE"] else { return }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gistpad-caret-\(run)-\(name)-\(UUID().uuidString).ready"
        )
        try Data("\(sample())".utf8).write(to: marker, options: .atomic)
        try await Task.sleep(for: .seconds(2))
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
