#if os(iOS)
import GistPadAccent
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
    @ScaledMetric(relativeTo: .title3) private var newGistSize = 26

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
                newGist.offset(x: 4 + newGistInset, y: -4 - newGistInset)
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
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Link(destination: GistPadLink.today.url) { dateBlock }
                Spacer(minLength: 0)
                newGist.offset(x: -3 - newGistInset, y: 4 + newGistInset)
            }
            // A fixed column keeps titles their room at accessibility sizes, widening only for a long weekday.
            .frame(minWidth: 100, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 0) {
                if recents.isEmpty {
                    note
                } else {
                    let shown = recents.prefix(dynamicTypeSize.isAccessibilitySize ? 2 : 3)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, gist in
                        if index > 0 { Divider().frame(height: 10) }
                        row(gist, lineLimit: 1, showsTime: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var dateBlock: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(date, format: .dateTime.weekday(.wide))
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

    private var newGistInset: CGFloat { max((44 - newGistSize) / 2, 0) }

    @ViewBuilder
    private var newGist: some View {
        if state != .signedOut {
            Button(intent: NewGistIntent()) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .widgetAccentable()
                    .frame(width: newGistSize, height: newGistSize)
                    .padding(newGistInset)
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
#endif
