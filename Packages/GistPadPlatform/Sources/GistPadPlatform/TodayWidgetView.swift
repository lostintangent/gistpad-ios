#if os(iOS)
import GistPadAppearance
import GistPadSync
import SwiftUI
import WidgetKit

public enum TodayWidgetState: Equatable, Sendable {
    case available, signedOut, locked, unavailable, placeholder
}

public struct TodayWidgetView: View {
    public static let kind = "GistPadToday"
    private let snapshot: NotebookSystemSnapshot?
    private let date: Date
    private let state: TodayWidgetState
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var dateSize = 38.0

    public init(
        snapshot: NotebookSystemSnapshot?, date: Date, state: TodayWidgetState
    ) {
        self.snapshot = snapshot
        self.date = date
        self.state = state
    }

    private var accent: Color {
        renderingMode == .fullColor ? Color(uiColor: AccentRole.text.uiColor) : .primary
    }
    private var today: SystemToday? {
        guard let today = snapshot?.today else { return nil }
        let timeZone = TimeZone(identifier: today.timeZoneIdentifier) ?? .current
        return today.filename == DailyNoteTarget(date: date, timeZone: timeZone).filename ? today : nil
    }
    private var destination: URL {
        state == .available ? today?.route.url ?? NotebookRoute.today.url : NotebookRoute.today.url
    }
    private var tasks: [TodayTask] { today?.tasks ?? [] }
    private var remaining: Int { tasks.filter { !$0.isCompleted }.count }

    public var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label {
                    Text(state == .available
                        ? (remaining == 0 ? String(localized: "Today") : String(localized: "\(remaining) remaining"))
                        : invitation)
                } icon: {
                    Image(systemName: "calendar")
                }
                .privacySensitive()
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(date, format: .dateTime.day())
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(date, format: .dateTime.weekday().month().day()))
            case .accessoryRectangular:
                rectangular
            case .systemMedium:
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        compactDate
                        content(limit: 1)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        dateColumn
                            .frame(maxWidth: 88, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            content(limit: 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 12) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(accessibleSummary)
                            .font(.subheadline)
                            .lineLimit(3)
                            .privacySensitive()
                        Spacer(minLength: 0)
                    } else {
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 1) {
                            GridRow {
                                Text(date, format: .dateTime.month(.abbreviated))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(accent)
                            }
                            GridRow(alignment: .top) {
                                Text(date, format: .dateTime.day())
                                    .font(.system(size: dateSize, weight: .semibold, design: .rounded))
                                    .foregroundStyle(accent)
                                    .contentTransition(.numericText())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Today").font(.headline)
                                    if state == .available, !tasks.isEmpty {
                                        Text("\(remaining) remaining")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .privacySensitive()
                                    }
                                }
                            }
                        }
                        content(limit: 1)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.personalAccent, PersonalAccent(savedHex: snapshot?.accentHex))
        .environment(\.timeZone, snapshot.flatMap {
            TimeZone(identifier: $0.today.timeZoneIdentifier)
        } ?? .current)
        .widgetURL(destination)
        .redacted(reason: state == .placeholder ? .placeholder : [])
    }

    private var compactDate: some View {
        Text(date, format: .dateTime.month(.abbreviated).day())
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(accent)
            .accessibilityLabel(Text("Today, \(date, format: .dateTime.month().day())"))
    }

    private var dateColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
            Text(date, format: .dateTime.day())
                .font(.system(size: dateSize, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
            Text("Today").font(.headline)
            if state == .available, !tasks.isEmpty {
                Text("\(remaining) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibleSummary: String {
        if state == .signedOut { return String(localized: "Sign in to GistPad") }
        guard state == .available else { return invitation }
        guard !tasks.isEmpty else { return today?.excerpt ?? invitation }
        return remaining == 1
            ? String(localized: "1 task remaining")
            : String(localized: "\(remaining) tasks remaining")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.caption.weight(.semibold))
            if state == .available, let task = tasks.first {
                taskButton(task, compact: true)
            } else {
                Text(invitation)
                    .font(.headline)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
    }

    @ViewBuilder
    private func content(limit: Int) -> some View {
        if state == .available, !tasks.isEmpty {
            ForEach(tasks.prefix(limit)) { task in
                taskButton(task, compact: false)
            }
            if today?.needsAttention == true {
                Label("Open GistPad", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(state == .available ? today?.excerpt ?? invitation : invitation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .privacySensitive()
        }
    }

    private var invitation: String {
        switch state {
        case .signedOut: String(localized: "Sign in to your notebook")
        case .locked: String(localized: "Unlock to see Today")
        case .unavailable: String(localized: "Open GistPad to refresh")
        case .available, .placeholder:
            today?.isAvailable == true ? String(localized: "Open Today") : String(localized: "Start Today")
        }
    }

    private func taskButton(_ task: TodayTask, compact: Bool) -> some View {
        Button(intent: SetTodayTaskIntent(task: task, completed: !task.isCompleted)) {
            HStack(spacing: 8) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(compact ? .title3 : .title2)
                    .foregroundStyle(accent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: compact ? 28 : 32, alignment: .leading)
                Text(task.title)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(compact ? 1 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .privacySensitive()
        .invalidatableContent()
        .accessibilityLabel(task.title)
        .accessibilityValue(task.isCompleted ? Text("Completed") : Text("Not completed"))
        .accessibilityHint(task.isCompleted ? Text("Mark incomplete") : Text("Complete task"))
        .accessibilityIdentifier("today-task-\(task.id)")
    }
}
#endif
