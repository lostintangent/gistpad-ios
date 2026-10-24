#if os(iOS)
import SwiftUI

public struct TodayLanding: View {
    private let summary: LibraryTodaySummary
    private let start: @MainActor () -> Void

    public init(summary: LibraryTodaySummary, start: @escaping @MainActor () -> Void) {
        self.summary = summary
        self.start = start
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TodayHeading(summary: summary)
                Text("Make room for a thought.", bundle: .module)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("One place for the things you notice, the ideas you want to keep, and what comes next.", bundle: .module)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Start today's note", bundle: .module), systemImage: "square.and.pencil", action: start)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("today-start")
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(InterfaceTheme.accent)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(Text("Today", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TodayHeading: View {
    let summary: LibraryTodaySummary
    @ScaledMetric(relativeTo: .largeTitle) private var daySize = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
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
    }

    private var dateHeading: some View {
        HStack(spacing: 16) {
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Today", bundle: .module)
                    .font(.title2.weight(.bold))
                Text(summary.date, format: contextFormat)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dayFormat: Date.FormatStyle {
        var style = Date.FormatStyle().day()
        style.timeZone = summary.timeZone
        return style
    }

    private var dayIdentity: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = summary.timeZone
        return calendar.dateComponents([.era, .year, .month, .day], from: summary.date)
    }

    private var contextFormat: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide)
        style.timeZone = summary.timeZone
        return style
    }

    private var compactDateFormat: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.abbreviated).day()
        style.timeZone = summary.timeZone
        return style
    }

    private var monthFormat: Date.FormatStyle {
        var style = Date.FormatStyle().month(.abbreviated)
        style.timeZone = summary.timeZone
        return style
    }

    private var fullDateFormat: Date.FormatStyle {
        Date.FormatStyle(date: .complete, time: .omitted, timeZone: summary.timeZone)
    }
}

struct TodayFeature: View {
    let summary: LibraryTodaySummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TodayHeading(summary: summary)
            if !dynamicTypeSize.isAccessibilitySize, let excerpt = summary.excerpt, !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let progress = summary.progress {
                TaskProgressLabel(progress: progress, showsRing: !dynamicTypeSize.isAccessibilitySize)
            }
            if summary.availability == .missing {
                Label(
                    String(localized: "Start today's note", bundle: .module),
                    systemImage: "arrow.up.right"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(InterfaceTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }
}

struct TaskProgressLabel: View {
    let progress: LibraryTaskProgress
    var showsRing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var ringSize = 20

    var body: some View {
        HStack(spacing: 8) {
            if showsRing, progress.total > 0 {
                ZStack {
                    Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: Double(progress.completed) / Double(progress.total))
                        .stroke(InterfaceTheme.accent, style: .init(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: ringSize, height: ringSize)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: progress.completed)
            }
            Text("\(progress.completed) of \(progress.total) tasks complete", bundle: .module)
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
