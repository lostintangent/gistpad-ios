#if os(iOS)
import SwiftUI

public struct TagLabel: View {
    private let tag: LibraryTag
    private let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(tag: LibraryTag, isSelected: Bool = false) {
        self.tag = tag
        self.isSelected = isSelected
    }

    public var body: some View {
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
        guard let rgb = TagSwatch.rgb(hex: hex) else {
            fill = Color(uiColor: .tertiarySystemFill)
            ink = .primary
            edge = nil
            return
        }
        let luminance = TagContrast.relativeLuminance(rgb)
        fill = TagSwatch.color(hex: hex)
        ink = TagContrast.prefersBlackInk(luminance: luminance) ? .black : .white
        // Near-white and near-black fills need an edge against the surface.
        edge = luminance >= 0.8 || luminance <= 0.05 ? Color(uiColor: .separator) : nil
    }
}

enum TagContrast {
    static func relativeLuminance(_ rgb: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 255) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    static func prefersBlackInk(luminance: Double) -> Bool {
        contrastRatio(luminance, 0) >= contrastRatio(luminance, 1)
    }

    static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
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
