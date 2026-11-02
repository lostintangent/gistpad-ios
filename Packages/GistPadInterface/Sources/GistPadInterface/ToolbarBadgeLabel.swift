#if os(iOS)
import SwiftUI
import UIKit

/// A quiet toolbar glyph with a monochrome count, because SwiftUI's toolbar badge is always red.
struct ToolbarBadgeLabel: View {
    let title: String
    let systemImage: String
    let count: Int?
    let isFilled: Bool
    @ScaledMetric(relativeTo: .caption2) private var countSize = 11
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // A single image keeps the native adaptive toolbar item instead of a custom-view item.
        Label {
            Text(verbatim: title)
        } icon: {
            Image(uiImage: ToolbarBadgeIcon.image(
                systemImage: systemImage, count: count, fontSize: min(countSize, 13),
                dark: colorScheme == .dark, scale: displayScale, isFilled: isFilled))
                .renderingMode(.original)
        }
    }
}

enum ToolbarBadgeIcon {
    static func image(
        systemImage: String, count: Int?, fontSize: CGFloat,
        dark: Bool, scale: CGFloat, isFilled: Bool
    ) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let ink = UIColor.label.resolvedColor(with: traits)
        let inverse = UIColor.systemBackground.resolvedColor(with: traits)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36), format: format).image { _ in
            UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 21, weight: .regular))?
                .withTintColor(isFilled ? inverse : ink, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 3, y: 9, width: 24, height: 24))
            guard let count, count > 0 else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: inverse,
            ]
            let text = (count > 99 ? "99+" : count.formatted(.number)) as NSString
            let size = text.size(withAttributes: attributes)
            let width = min(36, max(16, ceil(size.width) + 8))
            let pill = CGRect(x: 36 - width, y: 0, width: width, height: 16)
            let path = UIBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8)
            ink.setFill()
            path.fill()
            inverse.setStroke()
            path.lineWidth = 1
            path.stroke()
            text.draw(
                at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2),
                withAttributes: attributes)
        }
        .withAlignmentRectInsets(UIEdgeInsets(top: 9, left: 3, bottom: 3, right: 9))
        .withRenderingMode(.alwaysOriginal)
    }
}
#endif
