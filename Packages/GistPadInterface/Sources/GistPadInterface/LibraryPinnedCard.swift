#if os(iOS)
import SwiftUI

struct LibraryPinnedCard: View {
    let note: LibraryNote
    let tags: [LibraryTag]
    let isSelected: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: note.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .captureFrame("note-excerpt-\(note.id)")
            }
            if !tags.isEmpty {
                TagLabels(tags: tags, limit: 2)
                    .captureFrame("note-tags-\(note.id)")
            }
            if note.progress.map({ $0.total > 0 }) == true || note.visibleCommentCount != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { metadata }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .trailing, spacing: 8) { metadata }
                }
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .label))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .captureFrame("note-content-\(note.id)")
        .padding(14)
        .background(
            isSelected ? Color.clear : Color(uiColor: .secondarySystemBackground),
            in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: note.accessibilityDetail))
    }

    @ViewBuilder
    private var metadata: some View {
        if let progress = note.progress, progress.total > 0 {
            TaskProgressLabel(progress: progress, isOverdue: note.isOverdue)
                .captureFrame("note-progress-\(note.id)")
        }
        if let count = note.visibleCommentCount {
            LibraryCommentCount(count: count, noteID: note.id)
        }
    }
}
#endif
