import AppKit

/// Small glass hint shown above a control while the pointer rests on it, for controls in our
/// never-key panels.
///
/// AppKit tooltips (`toolTip`) only appear for the active app. Pri Notes stays in the background
/// so keyboard focus stays in Notes, so its tooltips never show. Tracking areas with
/// `.activeAlways` do report the pointer, and this draws its own hint in a borderless panel.
///
/// Example:
/// ```swift
/// let hints = HoverHint()
/// hints.attach(to: exportButton) { "Copy as Markdown, equations as LaTeX" }
/// ```
@MainActor
final class HoverHint: NSResponder {
    private let panel: ToolbarPanel
    private let glass = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")
    /// Hint text per control, read when the hint appears so it can change (e.g. a count).
    private var texts: [ObjectIdentifier: () -> String] = [:]
    private weak var hovered: NSView?
    private var pending: DispatchWorkItem?
    private static let delay = 0.45
    private static let padding = NSSize(width: 10, height: 5)

    override init() {
        panel = ToolbarPanel(interactive: false)   // never in the way of the pointer
        super.init()
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        let content = NSView()
        content.addSubview(label)
        glass.contentView = content
        panel.contentView = glass
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Show `text()` above `view` while the pointer rests on it.
    func attach(to view: NSView, text: @escaping () -> String) {
        texts[ObjectIdentifier(view)] = text
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: ["view": view])
        view.addTrackingArea(area)
    }

    /// Hide at once (e.g. on a click, or when the controls' panel hides).
    func hide() {
        pending?.cancel()
        hovered = nil
        panel.orderOut(nil)
    }

    override func mouseEntered(with event: NSEvent) {
        guard let view = event.trackingArea?.userInfo?["view"] as? NSView else { return }
        hovered = view
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.hovered === view else { return }
            self.show(above: view)
        }
        pending = work
        // A hint already up switches to the next control immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel.isVisible ? 0 : Self.delay), execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        guard let view = event.trackingArea?.userInfo?["view"] as? NSView, view === hovered else { return }
        hide()
    }

    private func show(above view: NSView) {
        guard let text = texts[ObjectIdentifier(view)]?(), !text.isEmpty,
              let window = view.window, window.isVisible else { return }
        label.stringValue = text
        label.sizeToFit()
        let p = Self.padding
        let size = NSSize(width: ceil(label.frame.width) + 2 * p.width, height: ceil(label.frame.height) + 2 * p.height)
        label.frame.origin = NSPoint(x: p.width, y: p.height)
        glass.cornerRadius = size.height / 2
        panel.setContentSize(size)

        // Centred above the control, kept on its screen.
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: window.frame.maxY + 2)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
            if origin.y + size.height > visible.maxY { origin.y = window.frame.minY - size.height - 2 }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }
}
