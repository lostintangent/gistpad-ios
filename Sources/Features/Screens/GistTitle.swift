#if os(iOS)
import SwiftUI

extension View {
    /// Shows a note's title at the leading end of the bar, with `filename` under it, in the same
    /// spot `GistScreen` puts it, but without glass, since it isn't a button.
    public func gistTitle(_ title: String, filename: String? = nil) -> some View {
        modifier(GistTitle<EmptyView>(title: title, filename: filename, pinnedWidth: 0, buttons: 0, menu: nil))
    }

    /// Shows a note's title at the leading end of the bar, as a glass button that opens `menu` when
    /// there is one. `pinnedWidth` is what the bar's pinned trailing items take, and `buttons`
    /// counts its other trailing buttons, besides Back or the sidebar toggle.
    func gistTitle<Choices: View>(
        _ title: String, filename: String?, pinnedWidth: CGFloat, buttons: Int, menu: Choices?
    ) -> some View {
        modifier(GistTitle(
            title: title, filename: filename, pinnedWidth: pinnedWidth, buttons: buttons, menu: menu))
    }
}

/// The system title menu would add a chevron and its own bar, so the title is a toolbar item in
/// the title's place, while `navigationTitle` still names the screen for Back and VoiceOver.
private struct GistTitle<Choices: View>: ViewModifier {
    let title: String
    let filename: String?
    let pinnedWidth: CGFloat
    let buttons: Int
    let menu: Choices?
    @State private var width: CGFloat = 0
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    /// The bar moves its leading item to the overflow menu when the item's ideal width doesn't fit,
    /// so a long title truncates first. Besides the margins and the capsule's insets, the title
    /// leaves room for the pinned items, and for Back or the sidebar toggle and the other buttons
    /// unless they stand in the vertical bar, as on the folded iPhone Duo.
    private var maxWidth: CGFloat? {
        guard width > 0 else { return nil }
        let room = toolbarVerticalEdge != nil
            ? width - 56 - pinnedWidth
            : width - 80 - CGFloat(buttons + 1) * (44 + 8) - pinnedWidth
        return max(room, 60)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if let menu {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            menu
                        } label: {
                            label
                        }
                        .menuIndicator(.hidden)
                        .accessibilityLabel(title)
                        .accessibilityValue(filename ?? "")
                        .accessibilityHint(Text("Shows the gist's files", bundle: .module))
                        .accessibilityIdentifier("note-title")
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        label
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(title)
                            .accessibilityValue(filename ?? "")
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("note-title")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let filename {
                Text(verbatim: filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: maxWidth, alignment: .leading)
        // The bar's first proposal can be narrower than the title, so it keeps its own width.
        .fixedSize(horizontal: true, vertical: false)
    }
}
#endif
