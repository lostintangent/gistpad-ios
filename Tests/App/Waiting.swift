import SwiftUI
import UIKit

// A test waits for the event that finishes what it started, never for time to pass. UIKit and
// SwiftUI lay out on demand, so a test calls `layoutIfNeeded()` and asserts at once. Observable
// state is awaited with `Observations`, and animations, transitions and the keyboard with their
// own completions. Each suite's `.timeLimit` ends a wait that never would.

/// Returns once `condition` holds, checking it again whenever the observable state it reads changes.
func until(_ condition: @escaping @MainActor () -> Bool) async {
    for await met in Observations(condition) where met { return }
}

/// Returns once `start` calls the completion it's handed, as an animation does when it's done.
func completion(_ start: (@escaping @Sendable () -> Void) -> Void) async {
    let (finished, finish) = AsyncStream<Never>.makeStream()
    start { finish.finish() }
    for await _ in finished {}
}

/// Returns at the screen's next `message`, as when the keyboard finishes coming up or going away.
func next<Message: NotificationCenter.MainActorMessage>(
    _ message: NotificationCenter.BaseMessageIdentifier<Message>
) async where Message.Subject == UIScreen {
    let (posted, post) = AsyncStream<Never>.makeStream()
    let center = NotificationCenter.default
    let token = center.addObserver(of: UIScreen.self, for: message) { _ in post.finish() }
    defer { center.removeObserver(token) }
    for await _ in posted {}
}

/// Returns once the keyboard, or a hardware keyboard's bar, is up over `view`, or gone from it.
func keyboard(visible: Bool, over view: UIView) async {
    view.layoutIfNeeded()
    let isVisible = view.keyboardLayoutGuide.layoutFrame.height > view.safeAreaInsets.bottom + 1
    guard isVisible != visible else { return }
    if visible { await next(.keyboardDidShow) } else { await next(.keyboardDidHide) }
    view.layoutIfNeeded()
}

/// Returns once the transitions running under `controller`, such as a push or a sheet, are done.
func transitions(under controller: UIViewController) async {
    func coordinators(_ controller: UIViewController) -> [any UIViewControllerTransitionCoordinator] {
        [controller.transitionCoordinator].compactMap(\.self)
            + controller.children.flatMap(coordinators)
            + (controller.presentedViewController.map(coordinators) ?? [])
    }
    var seen = Set<ObjectIdentifier>()
    for coordinator in coordinators(controller) where seen.insert(ObjectIdentifier(coordinator)).inserted {
        await completion { done in
            // A coordinator that's already finishing runs nothing more, so there's nothing to wait for.
            if !coordinator.animate(alongsideTransition: nil, completion: { _ in done() }) { done() }
        }
    }
}
