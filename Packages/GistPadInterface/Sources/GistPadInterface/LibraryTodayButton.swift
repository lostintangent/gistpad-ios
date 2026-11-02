#if os(iOS)
import SwiftUI

struct LibraryTodayButton: View {
    let summary: LibraryTodaySummary
    var isSelected = false
    let action: @MainActor () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isSelected }, set: { _ in action() })) {
            Label(String(localized: "Today", bundle: .module), systemImage: "calendar")
        }
        .toggleStyle(.button)
        .badge(summary.unfinishedTaskCount ?? 0)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("library-today")
    }

    private var accessibilityLabel: Text {
        let title = Text("Today", bundle: .module)
        if let count = summary.unfinishedTaskCount {
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
