import OSLog
import UIKit

/// The background time a publish gets after you leave the app. When the system takes it back,
/// `onExpiration` cancels the publish and the draft stays on this iPhone.
final class BackgroundLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    var onExpiration: (() -> Void)?

    var isActive: Bool { identifier != .invalid }

    init() {
        // UIKit calls this on the main actor, and the task has to end before it returns.
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Publish changes") {
            [weak self] in
            Logger(subsystem: "dev.gistpad.GistPad", category: "Library")
                .info("Background publish time expired. Local drafts are retained.")
            self?.onExpiration?()
            self?.end()
        }
    }

    func end() {
        onExpiration = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
