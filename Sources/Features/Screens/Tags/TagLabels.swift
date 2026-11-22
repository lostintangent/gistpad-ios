#if os(iOS)
import Appearance
import Store
import SwiftUI

struct TagLabel: View {
    let tag: Tag
    var isSelected = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let rgb = RGBColor(tagHex: tag.colorHex)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: tag.name)
                .fixedSize(horizontal: false, vertical: true)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(rgb?.contrastingInk ?? .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(rgb?.color ?? Color(uiColor: .tertiarySystemFill))
                .overlay {
                    if rgb?.needsEdge == true {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
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

    /// Black or white, whichever reads better on this fill.
    var contrastingInk: Color { contrast(with: .black) >= contrast(with: .white) ? .black : .white }
}

struct TagLabels: View {
    let tags: [Tag]
    var limit: Int?
    var isSelected = false
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let limit, !dynamicTypeSize.isAccessibilitySize {
                // Below accessibility sizes a limited line stays on one line:
                // as many tags as fit, else the first one truncated, plus a count.
                ViewThatFits(in: .horizontal) {
                    line(showing: limit)
                    line(showing: 1)
                    line(showing: 1).lineLimit(1)
                }
            } else {
                TagFlowLayout(layoutDirection: layoutDirection) {
                    ForEach(tags.prefix(limit ?? tags.count)) { TagLabel(tag: $0, isSelected: isSelected) }
                    if let limit, tags.count > limit {
                        overflow(tags.count - limit)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tags: \(tags.map(\.name).joined(separator: ", "))", bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func line(showing count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(tags.prefix(count)) { TagLabel(tag: $0, isSelected: isSelected) }
            if tags.count > count {
                overflow(tags.count - count)
                    .fixedSize()
            }
        }
    }

    private func overflow(_ count: Int) -> some View {
        Text("+\(count)", bundle: .module)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

private struct TagFlowLayout: Layout {
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
