#if os(iOS)
import SwiftUI

struct LibraryPinnedCard: View {
    let note: LibraryNote
    let tags: [LibraryTag]
    let isSelected: Bool
    var isSidebar = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: note.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: note.title))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .captureFrame("note-title-\(note.id)")
                Image(systemName: "pin.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if let excerpt = note.excerpt, !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: excerpt))
                    .captureFrame("note-excerpt-\(note.id)")
            }
            if !tags.isEmpty || hasMetadata {
                ViewThatFits(in: .horizontal) {
                    if tags.count >= 2 { footer(tagLimit: 2) }
                    if !tags.isEmpty { footer(tagLimit: 1) }
                    footer(tagLimit: 0)
                    footer(tagLimit: 0, showsProgressIndicator: false)
                }
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .label))
                .frame(maxWidth: .infinity, alignment: .leading)
                .captureFrame("note-footer-\(note.id)")
            }
        }
        .captureFrame("note-content-\(note.id)")
        .padding(dynamicTypeSize.isAccessibilitySize ? 12 : 14)
        .background(
            cardBackground,
            in: .rect(cornerRadius: 16))
        .overlay {
            if isSidebar && contrast == .increased {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isSelected ? Color(uiColor: .label) : Color("PinnedBoundary", bundle: .module),
                        lineWidth: isSelected ? 1.5 : 1 / displayScale)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .captureFrame("note-card-\(note.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: note.accessibilityDetail))
    }

    private var cardBackground: Color {
        if isSidebar {
            return Color(isSelected ? "PinnedSelectedSurface" : "PinnedSurface", bundle: .module)
        }
        return isSelected ? .clear : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func footer(tagLimit: Int, showsProgressIndicator: Bool = true) -> some View {
        HStack(spacing: 0) {
            if let first = tags.first {
                Group {
                    if tagLimit == 0 {
                        PinnedTagSummary(name: first.name, otherCount: tags.count - 1)
                    } else {
                        HStack(spacing: 6) {
                            ForEach(Array(tags.prefix(tagLimit))) { TagLabel(tag: $0) }
                            if tags.count > tagLimit {
                                PinnedTagSummary(otherCount: tags.count - tagLimit)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .layoutPriority(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Tags: \(tags.map(\.name).joined(separator: ", "))", bundle: .module))
                .captureFrame("note-tags-\(note.id)")
            }
            Spacer(minLength: tags.isEmpty || !hasMetadata ? 0 : footerSpacing(tagLimit: tagLimit))
            if hasMetadata {
                HStack(spacing: footerSpacing(tagLimit: tagLimit)) {
                    metadata(showsProgressIndicator: showsProgressIndicator)
                }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
        }
    }

    private func footerSpacing(tagLimit: Int) -> CGFloat {
        tagLimit == 0 && dynamicTypeSize.isAccessibilitySize ? 4 : 12
    }

    private var hasMetadata: Bool {
        note.progress.map { $0.total > 0 } == true || note.visibleCommentCount != nil
    }

    @ViewBuilder
    private func metadata(showsProgressIndicator: Bool) -> some View {
        if let progress = note.progress, progress.total > 0 {
            TaskProgressLabel(
                progress: progress, isOverdue: note.isOverdue, usesPrimaryInk: true,
                showsIndicator: showsProgressIndicator)
                .captureFrame("note-progress-\(note.id)")
        }
        if let count = note.visibleCommentCount {
            LibraryCommentCount(count: count, noteID: note.id)
                .labelStyle(.iconOnly)
        }
    }
}

private struct PinnedTagSummary: View {
    var name: String?
    let otherCount: Int
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            if let name {
                // Reserve three native-size characters before letting the decorative ring yield.
                Text(verbatim: name.count > 3 ? String(name.prefix(3)) + "…" : name)
                    .fixedSize()
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Text(verbatim: name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .captureFrame("pinned-tag-summary-name")
                    }
            }
            if otherCount > 0 {
                Text("+\(otherCount)", bundle: .module)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color(uiColor: .label))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 8))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.primary, lineWidth: 1)
            }
        }
    }
}
#endif
