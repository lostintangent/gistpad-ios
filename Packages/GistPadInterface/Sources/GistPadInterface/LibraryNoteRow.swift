#if os(iOS)
import SwiftUI

struct LibraryNoteRow: View {
    let note: LibraryNote
    let tags: [LibraryTag]
    var showsStar = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 14
    @ScaledMetric(relativeTo: .body) private var lineSpacing = 6

    var body: some View {
        TimelineView(.everyMinute) { context in
            let count = note.visibleCommentCount
            // Daily notes stay one line, and only tagged notes earn a second line.
            let rowTags = note.isDailyNote ? [] : tags
            VStack(alignment: .leading, spacing: lineSpacing) {
                titleRow(relativeTo: context.date, count: rowTags.isEmpty ? count : nil)
                if !rowTags.isEmpty {
                    HStack(spacing: 8) {
                        TagLabels(tags: rowTags, limit: 2)
                            .captureFrame("note-tags-\(note.id)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let count {
                            LibraryCommentCount(count: count, noteID: note.id)
                                .font(.footnote)
                        }
                    }
                }
            }
            .padding(.vertical, verticalPadding)
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: note.accessibilityDetail))
            .captureFrame("note-content-\(note.id)")
        }
    }

    @ViewBuilder
    private func titleRow(relativeTo now: Date, count: Int?) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            // A title too long to share its line moves the metadata beneath it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    titleContent(relativeTo: now)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    trailingMetadata(relativeTo: now, count: count)
                }
                VStack(alignment: .trailing, spacing: lineSpacing) {
                    titleContent(relativeTo: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingMetadata(relativeTo: now, count: count)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleContent(relativeTo: now)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingMetadata(relativeTo: now, count: count)
            }
        }
    }

    private func titleContent(relativeTo now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: displayTitle(relativeTo: now))
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .accessibilityLabel(Text(verbatim: spokenTitle))
                .captureFrame("note-title-\(note.id)")
            if note.isStarred && showsStar {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func trailingMetadata(relativeTo now: Date, count: Int?) -> some View {
        let updated = updateLabel(relativeTo: now)
        if note.isDailyNote {
            if let progress = note.progress, progress.total > 0 {
                TaskProgressLabel(progress: progress, isOverdue: note.isOverdue)
                    .fixedSize()
                    .captureFrame("note-progress-\(note.id)")
            }
        } else if count != nil || updated != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let count {
                    LibraryCommentCount(count: count, noteID: note.id)
                }
                if let updated {
                    Text(verbatim: updated)
                        .foregroundStyle(.secondary)
                        .captureFrame("note-date-\(note.id)")
                }
            }
            .font(.footnote)
            .fixedSize()
        }
    }

    private func updateLabel(relativeTo now: Date) -> String? {
        guard !note.isDailyNote, let updatedAt = note.updatedAt else { return nil }
        return LibraryDatePresentation.updateLabel(
            for: updatedAt, relativeTo: now, locale: locale, calendar: displayCalendar)
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

    private var displayCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }
}

struct LibraryCommentCount: View {
    let count: Int
    let noteID: String

    var body: some View {
        // Inline text keeps the glyph on the row's baseline. A Label here takes
        // List row icon layout, which hides the count and adds row height.
        Text("\(Image(systemName: "text.bubble")) \(count)", bundle: .module)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel(Text("\(count) comments", bundle: .module))
            .captureFrame("note-comment-count-\(noteID)")
    }
}

extension LibraryNote {
    var accessibilityDetail: String {
        var details: [String] = []
        if isPinned { details.append(String(localized: "Pinned", bundle: .module)) }
        if isStarred { details.append(String(localized: "Starred", bundle: .module)) }
        if gistID == nil {
            details.append(String(localized: "On this iPhone", bundle: .module))
        } else if isSecret {
            details.append(String(localized: "Unlisted gist", bundle: .module))
        } else {
            details.append(String(localized: "Public gist", bundle: .module))
        }
        if !isOwned, let owner {
            details.append(String(localized: "By \(owner)", bundle: .module))
        }
        return details.joined(separator: ", ")
    }
}
#endif
