#if DEBUG
  import GistPadEditor
  import GistPadInterface
  import SwiftUI
  import UIKit

  struct NotebookIntelligenceCaptureWorkspace: View {
    private let state: String
    private let accent: String?
    private let token: UUID?
    @State private var captureError: String?
    @State private var keyboardHeight: CGFloat = 0

    init() {
      let arguments = ProcessInfo.processInfo.arguments
      func argument(_ key: String) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
      }
      state = argument("--capture-state") ?? "ask"
      accent = argument("--capture-accent")
      token = argument("--capture-ready-token").flatMap(UUID.init(uuidString:))
    }

    var body: some View {
      NoteIntelligenceCaptureView(state: state, savedAccentHex: accent)
        .personalAccent(savedHex: accent)
        .task { await recordReadiness() }
        .onReceive(
          NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)
        ) { notification in
          guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
              .first
          else { return }
          keyboardHeight = max(
            0, scene.effectiveGeometry.coordinateSpace.bounds.intersection(frame).height)
        }
        .alert(
          "Capture couldn't settle",
          isPresented: Binding(
            get: { captureError != nil }, set: { if !$0 { captureError = nil } })
        ) {
          Button("OK") { captureError = nil }
        } message: {
          Text(captureError ?? "")
        }
    }

    @MainActor
    private func recordReadiness() async {
      guard let token else { return }
      var previous: Sample?
      var stableSamples = 0
      let started = ContinuousClock.now
      let deadline = Date().addingTimeInterval(12)
      do {
        while Date() < deadline {
          try Task.checkCancellation()
          if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow),
            let controller = window.rootViewController?.presentedViewController,
            !controller.isBeingPresented, let view = controller.view, view.bounds.width > 0
          {
            view.layoutIfNeeded()
            let scroll = descendants(view).compactMap { $0 as? UIScrollView }.filter {
              !($0 is UITextView)
            }.max { $0.contentSize.height < $1.contentSize.height }
            let end =
              scroll.map {
                max(
                  -$0.adjustedContentInset.top,
                  $0.contentSize.height - $0.bounds.height + $0.adjustedContentInset.bottom)
              } ?? 0
            if state.hasSuffix("-end"), let scroll,
              abs(scroll.contentOffset.y - end) > 1
            {
              scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
            }
            let sample = Sample(
              windowWidth: window.bounds.width, windowHeight: window.bounds.height,
              sheetFrame: view.convert(view.bounds, to: window),
              contentHeight: scroll?.contentSize.height ?? 0,
              offset: scroll?.contentOffset.y ?? 0,
              keyboardHeight: keyboardHeight,
              firstResponder: descendants(view).contains(where: \.isFirstResponder),
              scrollEndVisible: scroll == nil || abs((scroll?.contentOffset.y ?? 0) - end) <= 1,
              pendingProgressVisible: visibleProbe("intelligence-progress", in: view, window: window),
              pendingCancelVisible: visibleProbe("intelligence-cancel", in: view, window: window),
              pendingRequestVisible: visibleProbe(
                "intelligence-submitted-request", in: view, window: window,
                requiresFullVisibility:
                  !view.traitCollection.preferredContentSizeCategory.isAccessibilityCategory),
              hasResults: descendants(view).contains {
                $0.accessibilityIdentifier == "capture-frame-intelligence-results"
              },
              textSize: view.traitCollection.preferredContentSizeCategory.rawValue)
            let keyboardReady =
              state != "ask-keyboard"
              || (sample.firstResponder && sample.keyboardHeight >= 150)
            let scrollReady = !state.hasSuffix("-end")
              || (scroll != nil && sample.scrollEndVisible)
            let pendingReady = !state.hasPrefix("pending-")
              || (started.duration(to: .now) >= .seconds(5)
                && sample.pendingProgressVisible && sample.pendingCancelVisible
                && sample.pendingRequestVisible && !sample.hasResults)
            if keyboardReady, scrollReady, pendingReady, sample == previous {
              stableSamples += 1
            } else {
              stableSamples = 0
            }
            previous = sample
            if stableSamples >= 20 {
              let payload = Readiness(
                ready: true, state: state, accent: accent, explicitFakeModel: true, sample: sample)
              let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gistpad-capture-\(token.uuidString).ready")
              try JSONEncoder().encode(payload).write(to: url, options: .atomic)
              return
            }
          }
          try await Task.sleep(for: .milliseconds(16))
        }
        captureError =
          "The native sheet, scroll position or required keyboard did not become ready."
      } catch is CancellationError {
        return
      } catch {
        captureError = error.localizedDescription
      }
    }

    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func visibleProbe(
      _ id: String, in view: UIView, window: UIWindow, requiresFullVisibility: Bool = true
    ) -> Bool {
      guard let probe = descendants(view).first(where: {
        $0.accessibilityIdentifier == "capture-frame-\(id)"
      }), probe.window === window, !probe.isHidden, probe.alpha > 0 else { return false }
      let frame = probe.convert(probe.bounds, to: window)
      return !frame.isEmpty
        && (requiresFullVisibility ? window.bounds.contains(frame) : window.bounds.intersects(frame))
    }

    private struct Sample: Codable, Equatable {
      let windowWidth: CGFloat
      let windowHeight: CGFloat
      let sheetFrame: CGRect
      let contentHeight: CGFloat
      let offset: CGFloat
      let keyboardHeight: CGFloat
      let firstResponder: Bool
      let scrollEndVisible: Bool
      let pendingProgressVisible: Bool
      let pendingCancelVisible: Bool
      let pendingRequestVisible: Bool
      let hasResults: Bool
      let textSize: String
    }

    private struct Readiness: Encodable {
      let ready: Bool
      let state: String
      let accent: String?
      let explicitFakeModel: Bool
      let sample: Sample
    }
  }
#endif
