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
                Text("A little space for today's thoughts.", bundle: .module)
                    .font(.title2)
                    .foregroundStyle(.primary)
                Text("Start when you're ready. Nothing is created until you choose to begin.", bundle: .module)
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
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(Text("Today", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TodayHeading: View {
    let summary: LibraryTodaySummary

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(summary.date, format: dayFormat)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(InterfaceTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Today", bundle: .module)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary.date, format: contextFormat)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today", bundle: .module))
        .accessibilityValue(Text(summary.date, format: fullDateFormat))
    }

    private var dayFormat: Date.FormatStyle {
        var style = Date.FormatStyle().day()
        style.timeZone = summary.timeZone
        return style
    }

    private var contextFormat: Date.FormatStyle {
        var style = Date.FormatStyle().weekday(.wide).month(.wide)
        style.timeZone = summary.timeZone
        return style
    }

    private var fullDateFormat: Date.FormatStyle {
        Date.FormatStyle(date: .complete, time: .omitted, timeZone: summary.timeZone)
    }
}

struct TaskProgressLabel: View {
    let progress: LibraryTaskProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(progress.completed) of \(progress.total) tasks complete", bundle: .module)
                .font(.footnote)
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .tint(InterfaceTheme.accent)
                    .frame(maxWidth: 160)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
