#if os(iOS)
import SwiftUI

struct TodayHeading: View {
    let summary: LibraryTodaySummary
    var usesCompactLayout = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if usesCompactLayout || dynamicTypeSize.isAccessibilitySize {
                compactHeading
            } else {
                ViewThatFits(in: .horizontal) {
                    dateHeading.fixedSize(horizontal: true, vertical: false)
                    compactHeading
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today", bundle: .module))
        .accessibilityValue(Text(summary.date, format: fullDateFormat))
    }

    private var compactHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today", bundle: .module)
                .font(.title2.weight(.bold))
            Text(summary.date, format: compactDateFormat)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .captureFrame("today-compact-heading")
    }

    private var dateHeading: some View {
        HStack(spacing: 16) {
            TodayDateTile(summary: summary)
            TodayTitle(summary: summary)
        }
    }

    private var compactDateFormat: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.abbreviated).day()
        style.timeZone = summary.timeZone
        return style
    }

    private var fullDateFormat: Date.FormatStyle {
        Date.FormatStyle(date: .complete, time: .omitted, timeZone: summary.timeZone)
    }
}

private struct TodayTitle: View {
    let summary: LibraryTodaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today", bundle: .module)
                .font(.title2.weight(.bold))
            Text(summary.date, format: contextFormat)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .captureFrame("today-title")
    }

    private var contextFormat: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide)
        style.timeZone = summary.timeZone
        return style
    }
}

private struct TodayDateTile: View {
    let summary: LibraryTodaySummary
    @ScaledMetric(relativeTo: .largeTitle) private var daySize = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            Text(summary.date, format: monthFormat)
                .font(.footnote.weight(.semibold))
            Text(summary.date, format: dayFormat)
                .font(.system(size: daySize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: dayIdentity)
        }
        .foregroundStyle(InterfaceTheme.accent)
        .frame(minWidth: 56)
        .padding(12)
        .background(InterfaceTheme.selection, in: .rect(cornerRadius: 16))
        .accessibilityHidden(true)
        .accessibilityIdentifier("today-date-tile")
        .captureFrame("today-date-tile")
    }

    private var dayFormat: Date.FormatStyle {
        var style = Date.FormatStyle().day()
        style.timeZone = summary.timeZone
        return style
    }

    private var monthFormat: Date.FormatStyle {
        var style = Date.FormatStyle().month(.abbreviated)
        style.timeZone = summary.timeZone
        return style
    }

    private var dayIdentity: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = summary.timeZone
        return calendar.dateComponents([.era, .year, .month, .day], from: summary.date)
    }
}

struct TodayFeature: View {
    let summary: LibraryTodaySummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                compactContent
            } else {
                ViewThatFits(in: .horizontal) {
                    columns.frame(minWidth: 280, alignment: .leading)
                    compactContent
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today", bundle: .module))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("today-feature")
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 16) {
            TodayDateTile(summary: summary)
                .fixedSize()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    TodayTitle(summary: summary)
                    Spacer(minLength: 0)
                    if let progress {
                        TodayTaskState(progress: progress)
                            .fixedSize()
                            .captureFrame("today-tasks")
                    }
                }
                excerptOrInvitation
                    .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                TodayHeading(summary: summary, usesCompactLayout: true)
                Spacer(minLength: 0)
                if let progress {
                    TodayTaskState(progress: progress)
                        .fixedSize()
                        .captureFrame("today-tasks")
                }
            }
            excerptOrInvitation
        }
    }

    @ViewBuilder
    private var excerptOrInvitation: some View {
        if summary.availability == .missing {
            Label(
                String(localized: "Start today's note", bundle: .module),
                systemImage: "square.and.pencil"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(InterfaceTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            if let excerpt = summary.excerpt, !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today-excerpt")
                    .captureFrame("today-excerpt")
            }
        }
    }

    private var progress: LibraryTaskProgress? {
        guard summary.availability != .missing, let progress = summary.progress,
              progress.total > 0 else { return nil }
        return progress
    }

    private var accessibilityValue: Text {
        let date = Text(
            summary.date,
            format: Date.FormatStyle(date: .complete, time: .omitted, timeZone: summary.timeZone)
        )
        if let progress {
            let taskSummary = Text(
                "\(progress.completed) of \(progress.total) tasks complete, \(progress.remaining) left",
                bundle: .module
            )
            return Text("\(date), \(taskSummary)", bundle: .module)
        }
        if summary.availability == .missing {
            let invitation = Text("Start today's note", bundle: .module)
            return Text("\(date), \(invitation)", bundle: .module)
        }
        return date
    }
}

private struct TodayTaskState: View {
    let progress: LibraryTaskProgress
    @ScaledMetric(relativeTo: .body) private var ringSize = 32

    var body: some View {
        VStack(spacing: 4) {
            if progress.remaining == 0 {
                TaskCompletionMark(size: ringSize)
                    .accessibilityIdentifier("today-all-done")
            } else {
                ZStack {
                    Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: Double(progress.completed) / Double(progress.total))
                        .stroke(InterfaceTheme.accent, style: .init(lineWidth: 2, lineCap: .round))
                        .padding(1)
                        .rotationEffect(.degrees(-90))
                    Text(verbatim: String(progress.remaining))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(width: ringSize, height: ringSize)
                .accessibilityIdentifier("today-remaining-count")
                Text("left", bundle: .module)
                    .font(.caption)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TaskCompletionMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(InterfaceTheme.taskCompletion)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct TaskProgressLabel: View {
    let progress: LibraryTaskProgress
    var isOverdue = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var ringSize = 14

    var body: some View {
        HStack(spacing: 4) {
            if progress.remaining == 0 {
                TaskCompletionMark(size: ringSize)
            } else {
                ZStack {
                    Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: Double(progress.completed) / Double(progress.total))
                        .stroke(ink, style: .init(lineWidth: 2, lineCap: .round))
                        .padding(1)
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: ringSize, height: ringSize)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: progress.completed)
            }
            Text(verbatim: "\(progress.completed.formatted())/\(progress.total.formatted())")
                .font(.footnote)
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var ink: Color {
        isOverdue && progress.remaining > 0 ? InterfaceTheme.overdue : .secondary
    }

    private var accessibilitySummary: Text {
        let summary = Text("\(progress.completed) of \(progress.total) tasks complete", bundle: .module)
        if isOverdue && progress.remaining > 0 {
            let status = Text("Unfinished tasks", bundle: .module)
            return Text("\(summary), \(status)", bundle: .module)
        }
        return summary
    }
}
#endif
