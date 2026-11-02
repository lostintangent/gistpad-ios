#if os(iOS)
import GistPadAppearance
import SwiftUI

struct TagLabel: View {
    private let tag: LibraryTag
    private let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    init(tag: LibraryTag, isSelected: Bool = false) {
        self.tag = tag
        self.isSelected = isSelected
    }

    var body: some View {
        let style = TagLabelStyle(hex: tag.colorHex)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: tag.name)
                .fixedSize(horizontal: false, vertical: true)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(style.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(style.fill)
                .overlay {
                    if let edge = style.edge {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(edge, lineWidth: 0.5)
                    }
                }
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.primary, lineWidth: 1)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tag.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TagLabelStyle {
    let fill: Color
    let ink: Color
    let edge: Color?

    init(hex: String?) {
        guard let rgb = RGBColor(tagHex: hex) else {
            fill = Color(uiColor: .tertiarySystemFill)
            ink = .primary
            edge = nil
            return
        }
        fill = rgb.color
        ink = rgb.contrast(with: .black) >= rgb.contrast(with: .white) ? .black : .white
        edge = rgb.needsEdge ? Color(uiColor: .separator) : nil
    }
}

struct TagSwatch: View {
    let hex: String?
    var size: CGFloat = 12

    var body: some View {
        let rgb = RGBColor(tagHex: hex)
        Circle()
            .fill(rgb?.color ?? .secondary)
            .frame(width: size, height: size)
            .overlay {
                if rgb?.needsEdge == true {
                    Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }
}

extension RGBColor {
    /// Tag colors arrive with or without a leading "#".
    init?(tagHex: String?) {
        guard let tagHex else { return nil }
        self.init(hex: tagHex.hasPrefix("#") ? tagHex : "#" + tagHex)
    }

    /// Near-white and near-black fills need an edge against the surface.
    var needsEdge: Bool { luminance >= 0.8 || luminance <= 0.05 }
}

struct TagLabels: View {
    private let tags: [LibraryTag]
    private let limit: Int?
    private let isSelected: Bool
    @Environment(\.layoutDirection) private var layoutDirection

    init(tags: [LibraryTag], limit: Int? = nil, isSelected: Bool = false) {
        precondition(limit.map { $0 > 0 } ?? true)
        self.tags = tags
        self.limit = limit
        self.isSelected = isSelected
    }

    var body: some View {
        MetadataFlowLayout(layoutDirection: layoutDirection) {
            ForEach(visibleTags) { TagLabel(tag: $0, isSelected: isSelected) }
            if overflow > 0 {
                TagOverflowLabel(count: overflow)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tags: \(tags.map(\.name).joined(separator: ", "))", bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    struct TagOverflowLabel: View {
        let count: Int

        var body: some View {
            Text("+\(count)", bundle: .module)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 8))
        }
    }

    private var visibleTags: [LibraryTag] { Array(tags.prefix(limit ?? tags.count)) }
    private var overflow: Int { tags.count - visibleTags.count }
}

struct MetadataFlowLayout: Layout {
    var layoutDirection: LayoutDirection
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            let x = layoutDirection == .rightToLeft
                ? bounds.maxX - placement.origin.x - placement.size.width
                : bounds.minX + placement.origin.x
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY + placement.origin.y),
                anchor: .topLeading, proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, placements: [CGRect]) {
        let available = max(0, width ?? subviews.reduce(CGFloat.zero) {
            $0 + $1.sizeThatFits(.unspecified).width + spacing
        })
        var placements: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowStart = 0
        var usedWidth: CGFloat = 0
        func centerRow() {
            for index in rowStart..<placements.count {
                placements[index].origin.y += (rowHeight - placements[index].height) / 2
            }
        }
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
            if x > 0 && x + size.width > available {
                centerRow()
                rowStart = placements.count
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placements.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        centerRow()
        return (CGSize(width: width ?? usedWidth, height: y + rowHeight), placements)
    }
}
#endif
