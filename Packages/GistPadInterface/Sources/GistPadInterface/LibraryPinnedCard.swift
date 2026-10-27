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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                content.padding(12)
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { content.padding(12) }
            }
        }
        .background(cardBackground, in: .rect(cornerRadius: 16))
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: note.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : titleLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: note.title))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .captureFrame("note-title-\(note.id)")
                Image(systemName: "pin.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .captureFrame("note-pin-\(note.id)")
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            if !tags.isEmpty || hasMetadata {
                VStack(alignment: .leading, spacing: 4) {
                    if let first = tags.first {
                        ViewThatFits(in: .horizontal) {
                            if tags.count >= 2 { tagRow(limit: 2) }
                            tagRow(limit: 1)
                            PinnedTagSummary(name: first.name, otherCount: tags.count - 1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(
                            "Tags: \(tags.map(\.name).joined(separator: ", "))", bundle: .module))
                        .captureFrame("note-tags-\(note.id)")
                    }
                    if hasMetadata {
                        ViewThatFits(in: .horizontal) {
                            metadata(showsProgressIndicator: true)
                            metadata(showsProgressIndicator: false)
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .label))
                .frame(maxWidth: .infinity, alignment: .leading)
                .captureFrame("note-footer-\(note.id)")
            }
        }
        .captureFrame("note-content-\(note.id)")
    }

    private var titleLines: Int { !tags.isEmpty && hasMetadata ? 2 : 3 }

    private var cardBackground: Color {
        if isSidebar {
            return Color(isSelected ? "PinnedSelectedSurface" : "PinnedSurface", bundle: .module)
        }
        return isSelected ? .clear : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func tagRow(limit: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(tags.prefix(limit))) { TagLabel(tag: $0) }
            if tags.count > limit {
                PinnedTagSummary(otherCount: tags.count - limit)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var hasMetadata: Bool {
        note.progress.map { $0.total > 0 } == true || note.visibleCommentCount != nil
    }

    private func metadata(showsProgressIndicator: Bool) -> some View {
        HStack(spacing: 8) {
            if let progress = note.progress, progress.total > 0 {
                TaskProgressLabel(
                    progress: progress, isOverdue: note.isOverdue, usesPrimaryInk: true,
                    showsIndicator: showsProgressIndicator)
                    .fixedSize()
                    .captureFrame("note-progress-\(note.id)")
            }
            Spacer(minLength: 0)
            if let count = note.visibleCommentCount {
                LibraryCommentCount(count: count, noteID: note.id)
                    .labelStyle(.iconOnly)
            }
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
