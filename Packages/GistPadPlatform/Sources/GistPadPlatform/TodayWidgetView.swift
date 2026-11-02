#if os(iOS)
import GistPadAppearance
import GistPadSync
import SwiftUI
import WidgetKit

public enum TodayWidgetState: Equatable, Sendable {
    case available, signedOut, unavailable, placeholder
}

public struct TodayWidgetView: View {
    public static let kind = "GistPadToday"
    private let snapshot: NotebookSystemSnapshot?
    private let date: Date
    private let state: TodayWidgetState
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    private var today: DailyNote? {
        guard let today = snapshot?.today else { return nil }
        let timeZone = TimeZone(identifier: today.day.timeZoneIdentifier) ?? .current
        return today.day == DailyNoteTarget(date: date, timeZone: timeZone) ? today : nil
    }
    private var tasks: [FileTask] { today?.tasks ?? [] }
    private var remaining: Int { today?.progress?.remaining ?? 0 }
    private var needsAttention: Bool {
        switch today?.state {
        case .reconnect, .failed, .conflict: true
        default: false
        }
    }

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
            case .accessoryRectangular:
                rectangular
            default:
                VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 12) {
                    if family == .systemMedium, !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .top, spacing: 16) {
                            dateBlock
                            VStack(alignment: .leading, spacing: 4) {
                                content(limit: 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        dateBlock
                        content(limit: 1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.personalAccent, PersonalAccent(savedHex: snapshot?.accentHex))
        .environment(\.timeZone, snapshot.flatMap {
            TimeZone(identifier: $0.today.day.timeZoneIdentifier)
        } ?? .current)
        .widgetURL(NotebookRoute.today.url)
        .redacted(reason: state == .placeholder ? .placeholder : [])
    }

    private var dateBlock: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text(date, format: .dateTime.month(.abbreviated).day())
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(accent)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(date, format: .dateTime.month(.abbreviated))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                    HStack(alignment: .top, spacing: 12) {
                        Text(date, format: .dateTime.day())
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
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
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state == .available && !tasks.isEmpty
            ? Text("Today, \(date, format: .dateTime.month().day()), \(remaining) remaining")
            : Text("Today, \(date, format: .dateTime.month().day())"))
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
            if needsAttention {
                Label("Open GistPad", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(state == .available ? NotebookSystemSnapshot.excerpt(today?.text) ?? invitation : invitation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .privacySensitive()
        }
    }

    private var invitation: String {
        switch state {
        case .signedOut: String(localized: "Sign in to GistPad")
        case .unavailable: String(localized: "Open GistPad to refresh")
        case .available, .placeholder:
            today?.text != nil ? String(localized: "Open Today") : String(localized: "Start Today")
        }
    }

    private func taskButton(_ task: FileTask, compact: Bool) -> some View {
        Button(intent: SetTodayTaskIntent(task: task, completed: !task.isChecked)) {
            HStack(spacing: 8) {
                Image(systemName: task.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(compact ? .title3 : .title2)
                    .foregroundStyle(accent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: compact ? 28 : 32, alignment: .leading)
                Text(task.title)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(task.isChecked ? .secondary : .primary)
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
        .accessibilityValue(task.isChecked ? Text("Completed") : Text("Not completed"))
        .accessibilityHint(task.isChecked ? Text("Mark incomplete") : Text("Complete task"))
    }
}
#endif
