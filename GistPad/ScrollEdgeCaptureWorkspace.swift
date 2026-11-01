#if DEBUG
import GistPadEditor
import GistPadInterface
import GistPadPreview
import OSLog
import SwiftUI
import UIKit
import WebKit

struct ScrollEdgeCaptureWorkspace: View {
    private static let heading = "A useful pause"
    private static let markdown = """
        # A page in motion

        A quiet notebook keeps the thought in view while the controls stay close.

        """ + (1...18).map { index in
            """
            ## \(index == 9 ? heading : "Room for thought \(index)")

            Good tools make space for a thought to unfold. A sentence can begin as an observation, then become the start of something useful.

            Leave a little room for the next idea. The page continues beneath the glass, with the same clear rhythm from one passage to the next.

            """
        }.joined(separator: "\n")

    @State private var session = DocumentSession(
        documentID: "scroll-edge-fixture", text: markdown
    )
    @State private var mode: NoteMode
    @State private var path = [1]
    @State private var rendered = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var failure: String?
    private let token: String?
    private let supportedState: Bool
    private let wantsKeyboard: Bool
    private let wantsFind: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let state = argument("--capture-state") ?? "preview"
        supportedState = ["preview", "source", "source-keyboard", "source-find"].contains(state)
        wantsFind = state == "source-find"
        wantsKeyboard = state == "source-keyboard" || wantsFind
        _mode = State(initialValue: state == "preview" ? .reading : .source)
        token = argument("--capture-ready-token").flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
    }

    var body: some View {
        NavigationStack(path: $path) {
            if supportedState {
                List { Text("A page in motion") }
                    .navigationTitle("Library")
                    .navigationDestination(for: Int.self) { _ in
                        NoteScreen(
                            document: .init(
                                title: "A page in motion",
                                files: [.init(id: "README.md", filename: "README.md")],
                                selectedFileID: "README.md"
                            ),
                            mode: $mode, saveState: .inMemoryFixture, actions: actions
                        ) {
                            MarkdownEditorView(session: session)
                        } preview: {
                            MarkdownPreviewView(
                                document: session.text, documentID: session.documentID,
                                generation: session.generation
                            ) { event in
                                switch event {
                                case .rendered: rendered = true
                                case .failure(let error): failure = error.localizedDescription
                                default: break
                                }
                            }
                        }
                        .background {
                            ScrollEdgeReadiness(
                                source: session.textView, mode: mode, previewReady: rendered,
                                heading: Self.heading, token: token,
                                wantsKeyboard: wantsKeyboard, wantsFind: wantsFind,
                                keyboardHeight: keyboardHeight,
                                presentFind: {
                                    session.textView.findInteraction?.searchText = "Room for thought"
                                    session.presentFind(replacing: true)
                                }
                            ) { failure = $0 }
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Unknown scroll capture state", systemImage: "exclamationmark.triangle",
                    description: Text("Use preview or source.")
                )
            }
        }
        .personalAccent(savedHex: nil)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            keyboardHeight = scene.coordinateSpace.bounds.intersection(frame).height
        }
        .alert("Scroll Capture Unavailable", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var actions: NoteActions {
        var actions = NoteActions()
        actions.togglePin = {}
        actions.toggleStar = {}
        actions.share = {}
        actions.copyLink = {}
        actions.find = { mode = .source; session.presentFind(replacing: true) }
        actions.intelligence = {}
        return actions
    }
}

private struct ScrollEdgeReadiness: UIViewRepresentable {
    let source: UITextView
    let mode: NoteMode
    let previewReady: Bool
    let heading: String
    let token: String?
    let wantsKeyboard: Bool
    let wantsFind: Bool
    let keyboardHeight: CGFloat
    let presentFind: @MainActor () -> Void
    let failure: @MainActor (String) -> Void

    func makeUIView(context: Context) -> ScrollEdgeProbe { ScrollEdgeProbe() }

    func updateUIView(_ view: ScrollEdgeProbe, context: Context) {
        view.configure(
            source: source, mode: mode, previewReady: previewReady,
            heading: heading, token: token, wantsKeyboard: wantsKeyboard,
            wantsFind: wantsFind, keyboardHeight: keyboardHeight,
            presentFind: presentFind, failure: failure
        )
    }

    static func dismantleUIView(_ view: ScrollEdgeProbe, coordinator: ()) { view.stop() }
}

@MainActor
private final class ScrollEdgeProbe: UIView {
    private weak var source: UITextView?
    private weak var scrollView: UIScrollView?
    private var mode = NoteMode.reading
    private var previewReady = false
    private var heading = ""
    private var token: String?
    private var wantsKeyboard = false
    private var wantsFind = false
    private var keyboardHeight: CGFloat = 0
    private var requestedFocus = false
    private var requestedFind = false
    private var presentFind: (@MainActor () -> Void)?
    private var failure: (@MainActor (String) -> Void)?
    private var displayLink: CADisplayLink?
    private var resolvingHeading = false
    private var headingY: CGFloat?
    private var targetY: CGFloat?
    private var startedAt: CFTimeInterval?
    private var stableSince: CFTimeInterval?
    private var stableFrames = 0
    private var lastSample: Sample?
    private var finished = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        source: UITextView, mode: NoteMode, previewReady: Bool, heading: String,
        token: String?, wantsKeyboard: Bool, wantsFind: Bool, keyboardHeight: CGFloat,
        presentFind: @escaping @MainActor () -> Void,
        failure: @escaping @MainActor (String) -> Void
    ) {
        self.source = source
        self.mode = mode
        self.previewReady = previewReady
        self.heading = heading
        self.token = token
        self.wantsKeyboard = wantsKeyboard
        self.wantsFind = wantsFind
        self.keyboardHeight = keyboardHeight
        self.presentFind = presentFind
        self.failure = failure
        startIfAttached()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { startIfAttached() }
    }

    private func startIfAttached() {
        guard window != nil, token != nil, displayLink == nil, !finished else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let window, !finished else { return }
        if startedAt == nil { startedAt = link.timestamp }
        guard link.timestamp - (startedAt ?? link.timestamp) < 20 else {
            fail("The native scroll viewport did not settle within 20 seconds.")
            return
        }
        guard previewReady || mode == .source else { return }
        if wantsKeyboard, let source, source.window === window {
            if !requestedFocus {
                requestedFocus = true
                let range = (source.text as NSString).range(of: "## \(heading)")
                if range.location != NSNotFound { source.selectedRange = NSRange(location: range.location, length: 0) }
                guard source.becomeFirstResponder() else {
                    fail("The source editor could not receive keyboard focus.")
                    return
                }
            }
            guard source.isFirstResponder, keyboardHeight >= 150,
                  source.inputAccessoryView?.window != nil else { return }
            if wantsFind {
                if !requestedFind {
                    requestedFind = true
                    presentFind?()
                }
                guard source.findInteraction?.isFindNavigatorVisible == true else { return }
            }
        }
        if mode == .source, let source, targetY != nil {
            let range = (source.text as NSString).range(of: "## \(heading)")
            if range.location != NSNotFound,
               let position = source.position(from: source.beginningOfDocument, offset: range.location) {
                let currentY = source.caretRect(for: position).minY
                if let headingY, abs(currentY - headingY) > 0.5 {
                    stableSince = nil
                    stableFrames = 0
                    setTarget(currentY, scrollView: source)
                }
            }
        }
        if targetY == nil {
            prepareOffset(in: window)
            return
        }
        guard let scrollView, let targetY, scrollView.window === window else { return }
        guard !scrollView.isTracking, !scrollView.isDecelerating else { return }
        if abs(scrollView.contentOffset.y - targetY) > 0.5 {
            stableSince = nil
            stableFrames = 0
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            return
        }
        let sample = Sample(
            offset: scrollView.contentOffset, size: scrollView.contentSize,
            frame: scrollView.convert(scrollView.bounds, to: window),
            insets: scrollView.adjustedContentInset
        )
        if sample == lastSample {
            stableFrames += 1
        } else {
            lastSample = sample
            stableSince = link.timestamp
            stableFrames = 1
        }
        guard stableFrames >= 20, let stableSince, link.timestamp - stableSince >= 0.35 else { return }
        recordReady(sample: sample, window: window, stableDuration: link.timestamp - stableSince)
    }

    private func prepareOffset(in window: UIWindow) {
        guard !resolvingHeading else { return }
        if mode == .source {
            guard let source, source.window === window, source.bounds.height > 0 else { return }
            let range = (source.text as NSString).range(of: "## \(heading)")
            guard range.location != NSNotFound,
                  let position = source.position(from: source.beginningOfDocument, offset: range.location)
            else {
                fail("The source fixture's target heading could not be located.")
                return
            }
            source.layoutIfNeeded()
            if let manager = source.textLayoutManager, let range = manager.textContentManager?.documentRange {
                manager.ensureLayout(for: range)
            }
            setTarget(source.caretRect(for: position).minY, scrollView: source)
        } else {
            guard let preview = find(WKWebView.self, in: window), preview.bounds.height > 0 else { return }
            resolvingHeading = true
            Task { @MainActor [weak self, weak preview] in
                guard let self, let preview else { return }
                do {
                    let value = try await preview.callAsyncJavaScript(
                        """
                        const heading = [...document.querySelectorAll('h2')].find(node => node.textContent === title);
                        if (!heading) throw new Error('The preview target heading is missing.');
                        return heading.getBoundingClientRect().top + window.scrollY;
                        """,
                        arguments: ["title": self.heading], in: nil, contentWorld: .page
                    ) as? Double
                    guard let value, value.isFinite else {
                        self.fail("The preview returned an invalid target-heading position.")
                        return
                    }
                    self.setTarget(value, scrollView: preview.scrollView)
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func setTarget(_ y: CGFloat, scrollView: UIScrollView) {
        let target = y - scrollView.adjustedContentInset.top + 12
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom
        guard y.isFinite, target > minimum + scrollView.bounds.height,
              target < maximum - scrollView.bounds.height else {
            fail("The target heading is not in the middle of a laid-out document.")
            return
        }
        self.scrollView = scrollView
        headingY = y
        targetY = target
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    private func recordReady(sample: Sample, window: UIWindow, stableDuration: CFTimeInterval) {
        guard let token, let headingY, let targetY, let scrollView,
              let navigationBar = find(UINavigationBar.self, in: window) else {
            fail("The native navigation bar was not attached to the capture.")
            return
        }
        let navigationFrame = navigationBar.convert(navigationBar.bounds, to: window)
        let headingWindowY = scrollView.convert(CGPoint(x: 0, y: headingY), to: window).y
        guard abs(window.bounds.width - 466) <= 1,
              sample.frame.minY < navigationFrame.maxY,
              wantsKeyboard || sample.frame.maxY >= window.bounds.maxY - 1,
              headingWindowY < navigationFrame.maxY,
              wantsKeyboard == sourceIsFocused else {
            fail("The capture requires a 466-point viewport, real bar underlap and the requested keyboard state.")
            return
        }
        do {
            let accessoryFrame = source?.inputAccessoryView.map {
                NSCoder.string(for: $0.convert($0.bounds, to: window))
            } ?? ""
            let data = try JSONSerialization.data(withJSONObject: [
                "screen": "scroll-edges", "state": wantsKeyboard ? "source-keyboard" : mode == .source ? "source" : "preview",
                "fixture": "page-in-motion", "token": token,
                "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
                "contentSizeCategory": window.traitCollection.preferredContentSizeCategory.rawValue,
                "appearance": window.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
                "contentOffsetY": sample.offset.y, "targetOffsetY": targetY,
                "contentHeight": sample.size.height, "viewport": NSCoder.string(for: sample.frame),
                "adjustedInsets": NSCoder.string(for: sample.insets),
                "navigationBar": NSCoder.string(for: navigationFrame),
                "navigationBarMaxY": navigationFrame.maxY, "headingWindowY": headingWindowY,
                "stableFrames": stableFrames, "stableDuration": stableDuration,
                "keyboardVisible": sourceIsFocused && keyboardHeight >= 150,
                "keyboardHeight": keyboardHeight,
                "accessoryFrame": accessoryFrame,
            ], options: [.sortedKeys])
            try data.write(
                to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("gistpad-capture-\(token).ready"),
                options: .atomic
            )
            finished = true
            stop()
        } catch {
            fail("Capture readiness could not be recorded: \(error.localizedDescription)")
        }
    }

    private var sourceIsFocused: Bool { source?.isFirstResponder == true }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T, !match.isHidden { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func fail(_ message: String) {
        finished = true
        stop()
        Logger(subsystem: "dev.gistpad.GistPad", category: "ScrollEdgeCapture")
            .error("\(message, privacy: .public)")
        failure?(message)
    }

    private struct Sample: Equatable {
        let offset: CGPoint
        let size: CGSize
        let frame: CGRect
        let insets: UIEdgeInsets
    }
}
#endif
