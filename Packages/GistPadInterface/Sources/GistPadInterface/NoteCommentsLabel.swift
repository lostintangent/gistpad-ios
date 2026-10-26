#if os(iOS)
import SwiftUI

struct NoteCommentsLabel: View {
    let count: Int?
    let isSelected: Bool

    var body: some View {
        ToolbarBadgeLabel(
            title: "Comments", systemImage: "text.bubble", count: count, isSelected: isSelected)
    }
}
#endif
