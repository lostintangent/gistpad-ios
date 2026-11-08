#if os(iOS)
import SwiftUI

extension View {
    /// Shows a note's title as its screen will once it's open, for a note on its way or one that
    /// couldn't open, so nothing in the bar changes when the note arrives.
    public func gistTitle(_ gist: GistDetails) -> some View {
        modifier(GistTitle<EmptyView>(gist: gist, menu: nil))
    }

    /// Shows a note's title at the leading end of the bar, in glass, as a button that opens
    /// `menu` when there is one.
    func gistTitle<Choices: View>(_ gist: GistDetails, menu: Choices?) -> some View {
        modifier(GistTitle(gist: gist, menu: menu))
    }
}

/// The system title menu would add a chevron and its own bar, so the title is a toolbar item in
/// the title's place, while `navigationTitle` still names the screen for Back and VoiceOver.
private struct GistTitle<Choices: View>: ViewModifier {
    let gist: GistDetails
    let menu: Choices?
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private var title: String { gist.displayTitle(now: .now, locale: locale, calendar: calendar) }

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                // Every title is a bar button, so its capsule and text never move between notes,
                // or when a note arrives and its menu starts working.
                ToolbarItem(placement: .topBarLeading) {
                    if gist.isDailyNote {
                        Button {} label: { label }
                            .accessibilityLabel(title)
                            .accessibilityRemoveTraits(.isButton)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("note-title")
                    } else {
                        Menu {
                            menu
                        } label: {
                            label
                        }
                        .menuIndicator(.hidden)
                        .accessibilityLabel(title)
                        .accessibilityValue(gist.headerFilename ?? "")
                        .accessibilityIdentifier("note-title")
                    }
                }
            }
    }

    private var label: some View {
        TemplateWidth {
            // The user's measure for the longest title the bar shows before it ends in "…".
            Text(verbatim: "x coding agent culture")
                .font(.headline)
                .hidden()
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let filename = gist.headerFilename {
                    Text(verbatim: filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }
}

/// Sizes its second view to its own width, up to the width of its first, whatever the bar
/// proposes, so the bar never moves the title to its overflow menu.
private struct TemplateWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cap = subviews[0].sizeThatFits(.unspecified).width
        let width = min(subviews[1].sizeThatFits(.unspecified).width, cap)
        return subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews[0].place(at: bounds.origin, proposal: .zero)
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
