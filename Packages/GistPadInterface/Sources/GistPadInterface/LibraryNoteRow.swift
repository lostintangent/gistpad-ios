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
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 21
    @ScaledMetric(relativeTo: .body) private var titleSpacing = 3
    @ScaledMetric(relativeTo: .body) private var tagSpacing = 6

    var body: some View {
        TimelineView(.everyMinute) { context in
            let updated = updateLabel(relativeTo: context.date)
            let count = note.visibleCommentCount
            VStack(alignment: .leading, spacing: tagSpacing) {
                VStack(alignment: .leading, spacing: titleSpacing) {
                    // A row with no date line keeps its count on the title line,
                    // so the count never sits alone on a trailing line.
                    titleRow(relativeTo: context.date, count: updated == nil ? count : nil)
                    secondaryLine(updated: updated, count: updated == nil ? nil : count)
                }
                if !tags.isEmpty {
                    TagLabels(tags: tags, limit: 2)
                        .captureFrame("note-tags-\(note.id)")
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
        if let progress = note.progress, progress.total > 0 {
            if dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        titleContent(relativeTo: now, count: count)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        taskState(progress)
                    }
                    VStack(alignment: .leading, spacing: titleSpacing) {
                        titleContent(relativeTo: now, count: count)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        taskState(progress)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleContent(relativeTo: now, count: count)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    taskState(progress)
                }
            }
        } else {
            titleContent(relativeTo: now, count: count)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titleContent(relativeTo now: Date, count: Int?) -> some View {
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
            if let count {
                Spacer(minLength: 0)
                LibraryCommentCount(count: count, noteID: note.id)
            }
        }
    }

    private func taskState(_ progress: LibraryTaskProgress) -> some View {
        TaskProgressLabel(progress: progress, isOverdue: note.isOverdue)
            .fixedSize()
            .captureFrame("note-progress-\(note.id)")
    }

    private func updateLabel(relativeTo now: Date) -> String? {
        guard !note.isDailyNote, let updatedAt = note.updatedAt else { return nil }
        return LibraryDatePresentation.updateLabel(
            for: updatedAt, relativeTo: now, locale: locale, calendar: displayCalendar)
    }

    // Callers pass a count only when there is a date line to sit beside.
    @ViewBuilder
    private func secondaryLine(updated: String?, count: Int?) -> some View {
        let excerpt: String? = note.excerpt.flatMap { $0.isEmpty ? nil : $0 }
        if updated != nil || excerpt != nil {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // The count stays trailing on the date line and the excerpt takes
                    // the full width beneath it, so it is never narrowed into a column.
                    VStack(alignment: .leading, spacing: titleSpacing) {
                        if let updated {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                dateText(updated)
                                Spacer(minLength: 0)
                                if let count {
                                    LibraryCommentCount(count: count, noteID: note.id)
                                }
                            }
                        }
                        if let excerpt {
                            excerptText(excerpt)
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let updated {
                                dateText(updated)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if let excerpt {
                                excerptText(excerpt)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let count {
                            LibraryCommentCount(count: count, noteID: note.id)
                        }
                    }
                }
            }
            .font(.footnote)
            .captureFrame("note-secondary-\(note.id)")
        }
    }

    private func dateText(_ updated: String) -> some View {
        Text(verbatim: updated)
            .foregroundStyle(.secondary)
            .captureFrame("note-date-\(note.id)")
    }

    private func excerptText(_ excerpt: String) -> some View {
        Text(verbatim: excerpt)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
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
