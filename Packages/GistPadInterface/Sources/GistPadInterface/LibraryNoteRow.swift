#if os(iOS)
import SwiftUI

struct LibraryNoteRow: View {
    let note: LibraryNote
    let tags: [LibraryTag]
    var showsPin = true
    var showsStar = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 12
    @ScaledMetric(relativeTo: .body) private var titleSpacing = 3
    @ScaledMetric(relativeTo: .body) private var tagSpacing = 6

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: tagSpacing) {
                VStack(alignment: .leading, spacing: titleSpacing) {
                    titleRow(relativeTo: context.date)
                    secondaryLine(relativeTo: context.date)
                }
                if !tags.isEmpty {
                    TagLabels(tags: tags, limit: 2)
                        .captureFrame("note-tags-\(note.id)")
                }
            }
            .padding(.vertical, verticalPadding)
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: accessibilityDetail))
            .captureFrame("note-content-\(note.id)")
        }
    }

    @ViewBuilder
    private func titleRow(relativeTo now: Date) -> some View {
        if let progress = note.progress, progress.total > 0 {
            if dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        titleContent(relativeTo: now)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        taskState(progress)
                    }
                    VStack(alignment: .leading, spacing: titleSpacing) {
                        titleContent(relativeTo: now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        taskState(progress)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleContent(relativeTo: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    taskState(progress)
                }
            }
        } else {
            titleContent(relativeTo: now)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titleContent(relativeTo now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: displayTitle(relativeTo: now))
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .accessibilityLabel(Text(verbatim: spokenTitle))
                .captureFrame("note-title-\(note.id)")
            if note.isPinned && showsPin {
                Image(systemName: "pin.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if note.isStarred && showsStar {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func taskState(_ progress: LibraryTaskProgress) -> some View {
        TaskProgressLabel(progress: progress, isOverdue: note.isOverdue)
            .fixedSize()
            .captureFrame("note-progress-\(note.id)")
    }

    @ViewBuilder
    private func secondaryLine(relativeTo now: Date) -> some View {
        Group {
            if let count = note.visibleCommentCount {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: titleSpacing) {
                        metadata(relativeTo: now)
                        commentCount(count)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        metadata(relativeTo: now)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        commentCount(count)
                    }
                }
            } else {
                metadata(relativeTo: now)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color(uiColor: .label))
    }

    @ViewBuilder
    private func metadata(relativeTo now: Date) -> some View {
        Group {
            if note.isDailyNote {
                if let excerpt = note.excerpt, !excerpt.isEmpty {
                    excerptText(excerpt)
                        .captureFrame("note-secondary-\(note.id)")
                }
            } else {
                let updated = LibraryDatePresentation.updateLabel(
                    for: note.updatedAt, relativeTo: now, locale: locale, calendar: displayCalendar)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: titleSpacing) {
                            Text(verbatim: updated)
                                .captureFrame("note-date-\(note.id)")
                            if let excerpt = note.excerpt, !excerpt.isEmpty {
                                excerptText(excerpt)
                            }
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: updated)
                                .fixedSize(horizontal: true, vertical: false)
                                .captureFrame("note-date-\(note.id)")
                            if let excerpt = note.excerpt, !excerpt.isEmpty {
                                excerptText(excerpt)
                            }
                        }
                    }
                }
                .captureFrame("note-secondary-\(note.id)")
            }
        }
    }

    private func commentCount(_ count: Int) -> some View {
        Label {
            Text(count, format: .number)
        } icon: {
            Image(systemName: "text.bubble")
        }
        .fixedSize()
        .accessibilityLabel(
            Text("\(count) comments", bundle: .module)
        )
        .captureFrame("note-comment-count-\(note.id)")
    }

    private func excerptText(_ excerpt: String) -> some View {
        Text(verbatim: excerpt)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .captureFrame("note-excerpt-\(note.id)")
    }

    private func displayTitle(relativeTo now: Date) -> String {
        guard note.isDailyNote, let dailyDate = note.dailyDate else { return note.title }
        return LibraryDatePresentation.dailyTitle(
            for: dailyDate, relativeTo: now, locale: locale, calendar: displayCalendar)
    }

    private var spokenTitle: String {
        guard note.isDailyNote, let dailyDate = note.dailyDate else { return note.title }
        return dailyDate.formatted(Date.FormatStyle(
            date: .complete, time: .omitted, locale: locale,
            calendar: displayCalendar, timeZone: timeZone))
    }

    private var accessibilityDetail: String {
        var details: [String] = []
        if note.isPinned { details.append(String(localized: "Pinned", bundle: .module)) }
        if note.isStarred { details.append(String(localized: "Starred", bundle: .module)) }
        if note.gistID == nil {
            details.append(String(localized: "On this iPhone", bundle: .module))
        } else if note.isSecret {
            details.append(String(localized: "Unlisted gist", bundle: .module))
        } else {
            details.append(String(localized: "Public gist", bundle: .module))
        }
        if !note.isOwned, let owner = note.owner {
            details.append(String(localized: "By \(owner)", bundle: .module))
        }
        return details.joined(separator: ", ")
    }

    private var displayCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }
}
#endif
