#if os(iOS)
import Store
import SwiftUI

struct GistRow: View {
    let gist: GistItem
    let tags: [Tag]
    let today: Date
    var showsStar = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @ScaledMetric(relativeTo: .body) private var verticalPadding = 14
    @ScaledMetric(relativeTo: .body) private var lineSpacing = 6
    @ScaledMetric(relativeTo: .footnote) private var metadataSpacing = 8

    var body: some View {
        // Daily notes stay one line, and only tagged gists earn a tag line.
        let rowTags = gist.isDailyNote ? [] : tags
        // At accessibility sizes the row stacks, so the count joins the date
        // and the tag line holds only tags.
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let hasCounts = gist.visibleFileCount != nil || gist.visibleCommentCount != nil
        let countsOnTitleLine = hasCounts && (isStacked || rowTags.isEmpty)
        VStack(alignment: .leading, spacing: lineSpacing) {
            if isStacked {
                titleContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadata(showsCounts: countsOnTitleLine)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadata(showsCounts: countsOnTitleLine)
                }
            }
            if !rowTags.isEmpty {
                HStack(spacing: 8) {
                    TagLabels(tags: rowTags, limit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasCounts && !countsOnTitleLine {
                        counts
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
    private func metadata(showsCounts: Bool) -> some View {
        if gist.isDailyNote {
            if let progress = gist.progress, progress.total > 0 {
                TaskProgressLabel(progress: progress, isOverdue: gist.isOverdue)
                    .fixedSize()
            }
        } else if showsCounts || gist.updatedAt != nil {
            HStack(alignment: .firstTextBaseline, spacing: metadataSpacing) {
                if showsCounts {
                    counts
                }
                if let updatedAt = gist.updatedAt {
                    Text(verbatim: updatedAt.dayRelative(to: today, locale: locale, calendar: calendar))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .fixedSize()
        }
    }

    /// A file and comment count, which always travel together.
    private var counts: some View {
        // Inline text keeps each glyph on the row's baseline. A Label here takes
        // List row icon layout, which hides the count and adds row height.
        HStack(alignment: .firstTextBaseline, spacing: metadataSpacing) {
            if let files = gist.visibleFileCount {
                Text("\(Image(systemName: "doc.text")) \(files)", bundle: .module)
                    .accessibilityLabel(Text("\(files) files", bundle: .module))
            }
            if let comments = gist.visibleCommentCount {
                Text("\(Image(systemName: "text.bubble")) \(comments)", bundle: .module)
                    .accessibilityLabel(Text("\(comments) comments", bundle: .module))
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var displayTitle: String {
        gist.displayTitle(now: today, locale: locale, calendar: calendar)
    }

    private var spokenTitle: String {
        guard gist.isDailyNote, let dailyDate = gist.dailyDate else { return gist.title }
        return dailyDate.formatted(Date.FormatStyle(
            date: .complete, time: .omitted, locale: locale,
            calendar: calendar, timeZone: calendar.timeZone))
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
