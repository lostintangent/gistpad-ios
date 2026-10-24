#if os(iOS)
import GistPadAppearance
import SwiftUI
import WidgetKit

public enum TodayWidgetState: Equatable, Sendable {
    case available, signedOut, locked, unavailable, placeholder
}

public struct TodayWidgetView: View {
    public let snapshot: NotebookSystemSnapshot?
    public let date: Date
    public let state: TodayWidgetState
    private let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var dateSize = 38.0

    public init(
        snapshot: NotebookSystemSnapshot?, date: Date, state: TodayWidgetState,
        family: WidgetFamily? = nil
    ) {
        self.snapshot = snapshot
        self.date = date
        self.state = state
        familyOverride = family
    }

    private var family: WidgetFamily { familyOverride ?? widgetFamily }
    private var accent: Color {
        renderingMode == .fullColor ? Color(uiColor: AccentRole.text.uiColor) : .primary
    }
    private var today: SystemToday? {
        guard let today = snapshot?.today else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: today.timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let filename = String(
            format: "%04d-%02d-%02d.md",
            components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return today.filename == filename ? today : nil
    }
    private var destination: URL { today?.route.url ?? NotebookRoute.today.url }
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
                VStack(alignment: .leading, spacing: 8) {
                    if dynamicTypeSize.isAccessibilitySize {
                        compactDate
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(date, format: .dateTime.day())
                                .font(.system(size: dateSize, weight: .semibold, design: .rounded))
                                .foregroundStyle(accent)
                                .contentTransition(.numericText())
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Today").font(.headline)
                                Text(date, format: .dateTime.month(.abbreviated))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    content(limit: 1)
                }
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
            if !tasks.isEmpty {
                Text("\(remaining) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
            }
        }
        .accessibilityElement(children: .combine)
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
            if today?.issue != nil {
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
                    .frame(minWidth: compact ? 28 : 32)
                Text(task.title)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.primary)
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
