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
        .background(rgb?.color ?? Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 8))
        .overlay {
            // Increased Contrast's edge covers the hairline a near-white or near-black fill gets.
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.primary, lineWidth: 1)
            } else if rgb?.needsEdge == true {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tag.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TagSwatch: View {
    let hex: String?
    let size: CGFloat

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

/// A tag row in the tag filter and the tag editor, which toggles its checkmark when it has a `toggle`.
struct TagChoice: View {
    let tag: Tag
    let isSelected: Bool
    var count: Int?
    var toggle: (() -> Void)?
    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let toggle {
                Button(action: toggle) { row }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                row
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
    }

    private var row: some View {
        HStack(spacing: 12) {
            TagSwatch(hex: tag.colorHex, size: min(swatchSize, 24))
            Text(verbatim: tag.name)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let count {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // Reserves its width so the count never shifts when a tag is selected.
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(.rect)
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
                TagFlowLayout {
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

// Platform gap: SwiftUI has no wrapping stack. Remove TagFlowLayout when it ships one.
private struct TagFlowLayout: Layout {
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
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
