#if os(iOS)
import SwiftUI

struct GistRow: View {
    let gist: GistItem
    let tags: [Tag]
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
        let count = gist.visibleCommentCount
        // Daily notes stay one line, and only tagged gists earn a tag line.
        let rowTags = gist.isDailyNote ? [] : tags
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
                        CommentCount(count: count)
                            .font(.footnote)
                    }
                }
            }
        }
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: gist.accessibilityDetail))
    }

    private var titleContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: displayTitle)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .accessibilityLabel(Text(verbatim: spokenTitle))
            if gist.isStarred && showsStar {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func metadata(count: Int?) -> some View {
        if gist.isDailyNote {
            if let progress = gist.progress, progress.total > 0 {
                TaskProgressLabel(progress: progress, isOverdue: gist.isOverdue)
                    .fixedSize()
            }
        } else if count != nil || updateLabel != nil {
            HStack(alignment: .firstTextBaseline, spacing: metadataSpacing) {
                if let count {
                    CommentCount(count: count)
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
        guard !gist.isDailyNote, let updatedAt = gist.updatedAt else { return nil }
        return DateLabels.updateLabel(
            for: updatedAt, relativeTo: now, locale: locale, calendar: displayCalendar)
    }

    private var displayTitle: String {
        guard gist.isDailyNote, let dailyDate = gist.dailyDate else { return gist.title }
        return DateLabels.dailyTitle(
            for: dailyDate, relativeTo: now, locale: locale, calendar: displayCalendar)
    }

    private var spokenTitle: String {
        guard gist.isDailyNote, let dailyDate = gist.dailyDate else { return gist.title }
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

struct CommentCount: View {
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

extension GistItem {
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
