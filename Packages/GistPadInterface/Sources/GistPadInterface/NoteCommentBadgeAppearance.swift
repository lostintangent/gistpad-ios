#if os(iOS)
import SwiftUI
import UIKit

struct NoteCommentBadgeAppearance: UIViewControllerRepresentable {
    let label: String

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.label = label
        controller.updateBadge()
    }

    final class Controller: UIViewController {
        var label = ""

        override func loadView() {
            view = UIView()
            view.isHidden = true
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            updateBadge()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            updateBadge()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateBadge()
        }

        func updateBadge() {
            guard let owner = sequence(first: self as UIViewController, next: \.parent)
                .first(where: { candidate in
                    candidate.navigationController?.viewControllers.contains(where: { $0 === candidate }) == true
                }) else { return }
            let navigation = owner.navigationItem
            let groups = navigation.leadingItemGroups + navigation.centerItemGroups
                + navigation.trailingItemGroups
            let items = (navigation.leftBarButtonItems ?? []) + (navigation.rightBarButtonItems ?? [])
                + groups.flatMap(\.barButtonItems) + (owner.toolbarItems ?? [])
                + (owner.navigationController?.toolbar.items ?? [])
            guard let item = items.first(where: {
                $0.accessibilityIdentifier == "note-comments" || $0.accessibilityLabel == label
                    || $0.title == label
            }), var badge = item.badge else { return }
            badge.foregroundColor = .label
            badge.backgroundColor = .secondarySystemBackground
            badge.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .systemFont(ofSize: 11, weight: .semibold),
                maximumPointSize: 13, compatibleWith: owner.traitCollection)
            if item.badge != badge { item.badge = badge }
        }
    }
}
#endif
