import AppKit
import PriNotesCore

/// Content of the preview panel: the rendered equation centred above a one-line caption, with
/// identical padding on all four sides. Laid out by hand (no Auto Layout) so the insets are exact.
///
/// Example:
/// ```swift
/// let view = PreviewContentView()
/// let size = view.configure(image: equationImage, caption: "Type $ or ⌃⌘E to insert")
/// panel.setContentSize(size)
/// ```
final class PreviewContentView: NSGlassEffectView {
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 6
    static let minWidth: CGFloat = 80
    static let maxWidth: CGFloat = 900
    static let cornerRadius: CGFloat = 14

    /// Liquid Glass hosts its content in `contentView`; our subviews live there.
    private let content = NSView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .regular
        cornerRadius = PreviewContentView.cornerRadius
        imageView.imageScaling = .scaleProportionallyDown
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        content.addSubview(imageView)
        content.addSubview(caption)
        contentView = content
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lay out `image` (may be nil, e.g. on a LaTeX error) and `caption`; returns the view size.
    @discardableResult
    func configure(image: NSImage?, caption text: String) -> NSSize {
        let p = PreviewContentView.padding
        caption.stringValue = text
        let cellSize = caption.cell?.cellSize ?? caption.intrinsicContentSize
        let captionSize = NSSize(width: ceil(cellSize.width) + 2, height: ceil(cellSize.height))
        var imageSize = image?.size ?? .zero
        let maxInner = PreviewContentView.maxWidth - 2 * p
        if imageSize.width > maxInner {   // very long equations are scaled down to fit
            imageSize = NSSize(width: maxInner, height: imageSize.height * maxInner / imageSize.width)
        }
        let inner = min(max(imageSize.width, captionSize.width, PreviewContentView.minWidth - 2 * p), maxInner)
        let hasImage = image != nil
        let height = p + (hasImage ? imageSize.height + PreviewContentView.spacing : 0) + captionSize.height + p
        let size = NSSize(width: ceil(inner + 2 * p), height: ceil(height))

        // AppKit's origin is bottom-left: caption sits at the bottom, image above it.
        caption.frame = NSRect(x: p, y: p, width: size.width - 2 * p, height: captionSize.height)
        imageView.isHidden = !hasImage
        imageView.image = image
        imageView.frame = NSRect(x: ((size.width - imageSize.width) / 2).rounded(),
                                 y: p + captionSize.height + PreviewContentView.spacing,
                                 width: imageSize.width, height: imageSize.height)
        setFrameSize(size)
        content.frame = NSRect(origin: .zero, size: size)
        return size
    }
}

/// Floating, non-activating panel that shows a live rendering of the equation being typed.
///
/// `LivePreview.update()` is called after every keystroke/click in Notes. When the cursor is
/// inside a `$…` or `$$…` span it renders the span's source with MathJax and shows it just below
/// the opening delimiter; otherwise the panel is hidden.
@MainActor
final class LivePreview {
    var isEnabled = true

    private let formatter: Formatter
    private let panel: NSPanel
    private let content = PreviewContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    /// Incremented per update so late renders of stale source are dropped.
    private var generation = 0
    private var lastSource: String?

    init(formatter: Formatter) {
        self.formatter = formatter
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
    }

    func hide() {
        generation += 1
        lastSource = nil
        panel.orderOut(nil)
    }

    func update() {
        guard isEnabled, let ctx = formatter.currentContext(),
              let span = formatter.editingSpan(in: ctx.text, at: ctx.selection.location) else { return hide() }
        let family: RuleSet = span.display ? .renderedMath : .unicodeMath
        let source = ctx.text.substring(with: span.sourceRange)
            .replacingOccurrences(of: Formatter.zeroWidthSpace, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard formatter.enabled.contains(family), !source.isEmpty,
              span.display || !MathSpans.looksLikeMoney(source) else { return hide() }

        // Anchor below the opening delimiter so the panel doesn't chase the cursor.
        guard let anchor = ctx.ax.bounds(of: ctx.element, range: NSRange(location: span.fullRange.location, length: 1))
        else { return hide() }
        if source == lastSource, panel.isVisible { return position(below: anchor) }
        lastSource = source

        generation += 1
        let myGeneration = generation
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let captionText = LivePreview.caption(display: span.display)
        Task {
            let (image, text) = await LivePreview.render(source, caption: captionText, dark: dark, with: formatter.renderer)
            guard myGeneration == self.generation else { return }
            self.panel.setContentSize(self.content.configure(image: image, caption: text))
            self.position(below: anchor)
            self.panel.orderFrontRegardless()
        }
    }

    static func caption(display: Bool) -> String {
        display ? "$$ or ⌃⌘E to insert image" : "$ or ⌃⌘E to insert"
    }

    /// Render `source` for the panel; on a LaTeX error returns no image and the error as caption.
    static func render(_ source: String, caption: String, dark: Bool,
                       with renderer: MathRenderer) async -> (NSImage?, String) {
        do {
            let eq = try await renderer.render(source, fontSize: 20, dark: dark, embedSource: false)
            let image = NSImage(data: eq.png)
            image?.size = eq.size
            return (image, caption)
        } catch {
            return (nil, "⚠︎ " + error.localizedDescription)
        }
    }

    /// Place the panel under `anchor` (AX coordinates: top-left origin of the primary screen),
    /// or above it if there is no room below. The panel's left edge lines up with the `$`.
    private func position(below anchor: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let lineBottom = primary.frame.maxY - anchor.maxY
        let lineTop = primary.frame.maxY - anchor.minY
        var origin = NSPoint(x: anchor.minX - PreviewContentView.padding, y: lineBottom - panel.frame.height - 6)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.minX, y: lineBottom)) } ?? primary
        if origin.y < screen.visibleFrame.minY { origin.y = lineTop + 6 }
        origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - panel.frame.width))
        panel.setFrameOrigin(origin)
    }
}
