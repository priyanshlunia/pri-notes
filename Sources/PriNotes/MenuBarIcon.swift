import AppKit

/// The menu-bar icon: SF Symbol `text.badge.checkmark` with its checkmark badge replaced by an
/// italic Palatino "P" knocked out of the same filled circle, matching the app icon.
///
/// The result is a template image, so macOS tints it for light/dark menu bars and highlight.
///
/// Example:
/// ```swift
/// statusItem.button?.image = MenuBarIcon.make()
/// ```
enum MenuBarIcon {
    /// Badge circle geometry, as fractions of the symbol image, measured from the symbol rendered
    /// at 200 pt (247×220 px): centre (74, 66.5) from the top-left, diameter 99 px.
    private static let badgeCenterX: CGFloat = 74.0 / 247.0
    private static let badgeCenterYFromTop: CGFloat = 66.5 / 220.0
    private static let badgeDiameter: CGFloat = 99.0 / 247.0

    static func make(pointSize: CGFloat = 15) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = base.size

        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            base.draw(in: rect)

            let d = size.width * badgeDiameter
            let center = CGPoint(x: size.width * badgeCenterX, y: size.height * (1 - badgeCenterYFromTop))
            let circle = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)

            // Erase the original badge (slightly enlarged to catch its anti-aliased rim) …
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: circle.insetBy(dx: -d * 0.04, dy: -d * 0.04))
            // … redraw the filled circle …
            ctx.setBlendMode(.normal)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: circle)
            // … and knock the P out of it, centred on its ink rather than its advance box.
            let font = NSFont(name: "Palatino-BoldItalic", size: d * 0.86) ?? NSFont.boldSystemFont(ofSize: d * 0.75)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "P", attributes: [.font: font, .foregroundColor: NSColor.black]))
            let ink = CTLineGetImageBounds(line, ctx)
            ctx.setBlendMode(.destinationOut)
            ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = true
        image.alignmentRect = base.alignmentRect
        image.accessibilityDescription = "Pri Notes"
        return image
    }
}
