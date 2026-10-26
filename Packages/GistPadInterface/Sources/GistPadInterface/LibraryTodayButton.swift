#if os(iOS)
import SwiftUI

public struct LibraryTodayButton: View {
    private let summary: LibraryTodaySummary
    private let isSelected: Bool
    private let action: @MainActor () -> Void

    public init(
        summary: LibraryTodaySummary, isSelected: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.summary = summary
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Toggle(isOn: Binding(get: { isSelected }, set: { _ in action() })) {
            ToolbarBadgeLabel(
                title: "Today", systemImage: "calendar",
                count: summary.unfinishedTaskCount, isSelected: isSelected)
        }
        .toggleStyle(.button)
        .tint(.primary)
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
