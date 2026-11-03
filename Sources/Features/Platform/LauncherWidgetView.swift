#if os(iOS)
import Accent
import SwiftUI
import WidgetKit

public enum LauncherWidgetState: Equatable, Sendable {
    case available, signedOut, unavailable, placeholder
}

/// The GistPad widget, a launcher into today's note, a recent gist or a new one.
public struct LauncherWidgetView: View {
    /// Kept from the Today widget it replaced, so widgets already on a Home Screen stay.
    public static let kind = "GistPadToday"
    private let snapshot: LibrarySnapshot?
    private let date: Date
    private let state: LauncherWidgetState
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    public init(snapshot: LibrarySnapshot?, date: Date, state: LauncherWidgetState) {
        self.snapshot = snapshot
        self.date = date
        self.state = state
    }

    private var accent: Color {
        renderingMode == .fullColor ? Color(uiColor: AccentRole.text.uiColor) : .primary
    }
    private var recents: [GistEntity] {
        state == .available || state == .placeholder ? snapshot?.recents ?? [] : []
    }

    public var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .environment(\.accent, Accent(savedHex: snapshot?.accentHex))
        .widgetURL(family == .systemMedium ? nil : GistPadLink.today.url)
        .redacted(reason: state == .placeholder ? .placeholder : [])
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                dateBlock
                Spacer(minLength: 0)
                // The pencil sits optically on the margins, past its larger tap area.
                newGist.offset(x: newGistPad + 3, y: -newGistPad - 3)
            }
            Spacer(minLength: 0)
            if let gist = recents.first {
                row(gist, lineLimit: 2, showsTime: !dynamicTypeSize.isAccessibilitySize)
            } else {
                note
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: dateGap) {
            Link(destination: GistPadLink.today.url) {
                dateBlock { Text(date, format: .dateTime.weekday(.wide)) }
            }
            // Spelled out and hugging today's weekday, so the gap to the list is the same every day.
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            ZStack(alignment: .topLeading) {
                rowSlots
                VStack(alignment: .leading, spacing: 0) {
                    if recents.isEmpty {
                        note
                    } else {
                        ForEach(Array(recents.prefix(rowCount).enumerated()), id: \.element.id) { index, gist in
                            if index > 0 { Divider().frame(height: rowGap) }
                            row(gist, lineLimit: 1, showsTime: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: Alignment(horizontal: .leading, vertical: .lastRowBaseline)) {
            newGist.offset(x: -newGistPad - 2)
        }
    }

    private var rowCount: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 3 }
    private let rowGap: CGFloat = 10
    /// Between medium's date column and its list, a little roomier than the widget's margin.
    private let dateGap: CGFloat = 20

    /// A full list's rows, unseen, so New Gist mirrors the date: its square sits on the last row's
    /// baseline as the weekday's cap top meets the first title's, however many gists there are.
    private var rowSlots: some View {
        VStack(alignment: .leading, spacing: rowGap) {
            ForEach(1..<rowCount, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: " ").font(.subheadline.weight(.semibold))
                    Text(verbatim: " ").font(.footnote)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: " ").font(.subheadline.weight(.semibold))
                Text(verbatim: " ").font(.footnote)
                    .alignmentGuide(.lastRowBaseline) { $0[.lastTextBaseline] }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var dateBlock: some View {
        dateBlock {
            ViewThatFits(in: .horizontal) {
                Text(date, format: .dateTime.weekday(.wide))
                Text(date, format: .dateTime.weekday(.abbreviated))
            }
        }
    }

    private func dateBlock(@ViewBuilder weekday: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            weekday()
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .widgetAccentable()
            Text(date, format: .dateTime.day())
                .font(.largeTitle)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today, \(date, format: .dateTime.weekday(.wide).month(.wide).day())"))
    }

    /// A fixed pad, not a scaled frame, since widgets stop growing text before Dynamic Type does.
    private let newGistPad: CGFloat = 10

    @ViewBuilder
    private var newGist: some View {
        if state != .signedOut {
            Button(intent: NewGistIntent()) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .widgetAccentable()
                    // The square's bottom edge hangs just under halfway from the symbol's baseline to its bounds.
                    .alignmentGuide(.lastRowBaseline) { $0[.lastTextBaseline] + ($0[.bottom] - $0[.lastTextBaseline]) * 0.45 }
                    .padding(newGistPad)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("New Gist"))
        }
    }

    private func row(_ gist: GistEntity, lineLimit: Int, showsTime: Bool) -> some View {
        Button(intent: OpenGistIntent(target: gist)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: gist.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(lineLimit)
                    .privacySensitive()
                if showsTime, let updatedAt = gist.updatedAt {
                    Text(verbatim: timeLabel(for: updatedAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var note: some View {
        Group {
            switch state {
            case .signedOut: Text("Sign in with GitHub")
            case .unavailable: Text("Open GistPad to refresh")
            case .available, .placeholder: Text("No recent gists")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// Dated like the gist list: a time today, then Yesterday, a weekday this week, or the date.
    private func timeLabel(for updatedAt: Date) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(updatedAt, inSameDayAs: date) {
            return updatedAt.formatted(style.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: date),
           calendar.isDate(updatedAt, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", locale: locale)
        }
        if calendar.isDate(updatedAt, equalTo: date, toGranularity: .weekOfYear) {
            return updatedAt.formatted(style.weekday(.wide))
        }
        let day = style.month(.defaultDigits).day()
        return updatedAt.formatted(
            calendar.isDate(updatedAt, equalTo: date, toGranularity: .year) ? day : day.year())
    }
}

private extension VerticalAlignment {
    private enum LastRowBaseline: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }

    static let lastRowBaseline = VerticalAlignment(LastRowBaseline.self)
}
#endif
