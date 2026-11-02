#if os(iOS)
import SwiftUI

struct LibraryNoteRow: View {
    let note: LibraryNote
    let tags: [LibraryTag]
    let now: Date
    var showsStar = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 14
    @ScaledMetric(relativeTo: .body) private var lineSpacing = 6
    @ScaledMetric(relativeTo: .footnote) private var metadataSpacing = 8

    var body: some View {
        let count = note.visibleCommentCount
        // Daily notes stay one line, and only tagged notes earn a tag line.
        let rowTags = note.isDailyNote ? [] : tags
        // At accessibility sizes the row stacks, so the count joins the date
        // and the tag line holds only tags.
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let countOnTitleLine = isStacked || rowTags.isEmpty
        VStack(alignment: .leading, spacing: lineSpacing) {
            if isStacked {
                titleContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadata(count: count)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadata(count: countOnTitleLine ? count : nil)
                }
            }
            if !rowTags.isEmpty {
                HStack(spacing: 8) {
                    TagLabels(tags: rowTags, limit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let count, !countOnTitleLine {
                        LibraryCommentCount(count: count)
                            .font(.footnote)
                    }
                }
            }
        }
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: note.accessibilityDetail))
    }

    private var titleContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: displayTitle)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .accessibilityLabel(Text(verbatim: spokenTitle))
            if note.isStarred && showsStar {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func metadata(count: Int?) -> some View {
        if note.isDailyNote {
            if let progress = note.progress, progress.total > 0 {
                TaskProgressLabel(progress: progress, isOverdue: note.isOverdue)
                    .fixedSize()
            }
        } else if count != nil || updateLabel != nil {
            HStack(alignment: .firstTextBaseline, spacing: metadataSpacing) {
                if let count {
                    LibraryCommentCount(count: count)
                }
                if let updateLabel {
                    Text(verbatim: updateLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .fixedSize()
        }
    }

    private var updateLabel: String? {
        guard !note.isDailyNote, let updatedAt = note.updatedAt else { return nil }
        return LibraryDatePresentation.updateLabel(
            for: updatedAt, relativeTo: now, locale: locale, calendar: displayCalendar)
    }

    private var displayTitle: String {
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

    var body: some View {
        // Inline text keeps the glyph on the row's baseline. A Label here takes
        // List row icon layout, which hides the count and adds row height.
        Text("\(Image(systemName: "text.bubble")) \(count)", bundle: .module)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel(Text("\(count) comments", bundle: .module))
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
