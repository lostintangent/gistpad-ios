#if os(iOS)
import SwiftUI

public struct TagLabel: View {
    private let tag: LibraryTag
    private let isSelected: Bool
    @ScaledMetric(relativeTo: .footnote) private var swatchSize: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(tag: LibraryTag, isSelected: Bool = false) {
        self.tag = tag
        self.isSelected = isSelected
    }

    public var body: some View {
        let swatchSize = self.swatchSize
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TagSwatch(hex: tag.colorHex, size: swatchSize)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + swatchSize * 0.3 }
            Text(verbatim: tag.name)
                .fixedSize(horizontal: false, vertical: true)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(InterfaceTheme.accent)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(TagSwatch.color(hex: tag.colorHex).opacity(colorScheme == .dark ? 0.28 : 0.24))
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

public struct TagLabels: View {
    private let tags: [LibraryTag]
    private let limit: Int?
    private let isSelected: Bool
    @Environment(\.layoutDirection) private var layoutDirection

    public init(tags: [LibraryTag], limit: Int? = nil, isSelected: Bool = false) {
        precondition(limit.map { $0 > 0 } ?? true)
        self.tags = tags
        self.limit = limit
        self.isSelected = isSelected
    }

    public var body: some View {
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
