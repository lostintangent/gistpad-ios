#if os(iOS)
import Sync
import SwiftUI

struct TodayButton: View {
    let summary: DailyNote
    let action: @MainActor () -> Void

    var body: some View {
        // The toggle's native fill shows that today has a page.
        Toggle(isOn: Binding(get: { summary.text != nil }, set: { _ in action() })) {
            ToolbarBadgeLabel(
                title: String(localized: "Today", bundle: .module), systemImage: "calendar",
                count: summary.progress?.remaining, isFilled: summary.text != nil)
        }
        .toggleStyle(.button)
        .tint(.primary)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("library-today")
    }

    private var accessibilityLabel: Text {
        let title = Text("Today", bundle: .module)
        if let count = summary.progress?.remaining {
            let status = count == 0
                ? Text("No unfinished tasks", bundle: .module)
                : Text("\(count) unfinished tasks", bundle: .module)
            return Text("\(title), \(status)", bundle: .module)
        } else {
            return title
        }
    }
}
#endif
