import AppKit
import PriNotesCore

// MARK: - Controls that work in a non-activating panel

/// Buttons and pop-ups in a panel that never becomes key must accept the first click, otherwise
/// the first click would only try (and fail) to focus the panel.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstClickPopUp: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The shared shell of the selection toolbar, the note footer and hover hints: a borderless, clear,
/// floating panel on every Space that never becomes key, so keyboard focus and the selection stay in
/// Notes. Liquid Glass draws its own shadow, so the window has none.
final class ToolbarPanel: NSPanel {
    /// `interactive`: take clicks over the whole panel. By default a clear, borderless window only
    /// takes clicks on its opaque pixels; our controls are borderless, so the glass is their only
    /// background, and on macOS 26 the glass apparently doesn't count, which let clicks fall through
    /// to Notes. Non-interactive panels (hover hints) let every click through.
    convenience init(interactive: Bool) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                  styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = !interactive
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }    // keep keyboard focus (and the selection) in Notes
    override var canBecomeMain: Bool { false }
}

/// The toolbar's root view. It hit-tests the toolbar's controls directly instead of walking down through
/// the glass views. On macOS 26 the toolbar drew but ignored every click, while macOS 27 was fine.
/// `NSGlassEffectView` re-parents and lays out its `contentView` itself, and if a control ends up
/// outside an intermediate view's bounds, AppKit still draws it but the normal hit test never
/// reaches it. Searching the controls by their own frames works however the glass arranges them.
final class ToolbarGlassContainer: NSGlassEffectContainerView {
    /// Every clickable control in the toolbar.
    var controls: [NSControl] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates.
        let local = superview.map { convert(point, from: $0) } ?? point
        for control in controls where !control.isHiddenOrHasHiddenAncestor {
            if control.bounds.contains(control.convert(local, from: self)) { return control }
        }
        return super.hitTest(point)
    }
}

// MARK: - Toolbar

/// Floating Liquid Glass toolbar shown above selected text in Notes:
/// `[ Font ▾ | Typeface ▾ ]  [ B I U S ]  [ − 13 + ]  [ ● ▾ ]  [ 📁🔗 ]  [ ∑ ▾ ]`
///
/// The ∑ capsule appears only when the selection is a converted equation: it switches the equation
/// between text and image and copies it as LaTeX or MathML. A selected image shows the ∑ capsule
/// alone, since the style controls don't apply to it.
///
/// `update()` is called after every key or click in Notes. When text is selected it waits for a short
/// pause, reads the selection's style (`SelectionStyler`) and shows the toolbar centred above it.
/// It hides when the selection is cleared, on Esc (until the selection changes), or when Notes goes
/// to the background, except while the colour panel is open.
@MainActor
final class SelectionToolbar: NSObject, NSMenuDelegate {
    var isEnabled = true
    /// The link button: turn the selection into a link to an iCloud Drive item (`FileLinkInserter`).
    var onInsertFileLink: (() -> Void)?

    private let formatter: Formatter
    private let styler: SelectionStyler
    private let panel: ToolbarPanel
    private var pending: DispatchWorkItem?
    private var selection: NSRange?
    private var dismissedSelection: NSRange?
    private var colorSession = false
    private var colorPanelPick: NSColor?
    /// True while one of the toolbar's menus is open: the menus must not be rebuilt then.
    private var menuOpen = false

    // Controls
    private let familyPopUp = FirstClickPopUp(frame: .zero, pullsDown: true)
    private let facePopUp = FirstClickPopUp(frame: .zero, pullsDown: true)
    private let sizePopUp = FirstClickPopUp(frame: .zero, pullsDown: true)
    private let colorPopUp = FirstClickPopUp(frame: .zero, pullsDown: true)
    private let equationPopUp = FirstClickPopUp(frame: .zero, pullsDown: true)
    /// The ∑ capsule, shown only for equations; the other capsules are hidden for a selected image.
    private var equationGlass: NSGlassEffectView!
    private var toggleButtons: [SelectionStyler.InlineStyleToggle: FirstClickButton] = [:]
    private var groups: [(glass: NSGlassEffectView, stack: NSStackView)] = []
    private let container = ToolbarGlassContainer()
    /// Hover notes for the controls: AppKit tooltips never show for a background app (see HoverHint).
    private let hints = HoverHint()
    private static let groupSpacing: CGFloat = 6
    private static let outerMargin: CGFloat = 6   // room for the glass shadow

    /// Families listed first in the font menu (only those installed are shown).
    static let curatedFamilies = [StyleSample.systemFamilyLabel, "Palatino", "Helvetica Neue", "Avenir Next",
                                  "Georgia", "Times New Roman", "Baskerville", "Menlo", "SF Mono"]
    static let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64]
    /// Palette colours: system colours adapt their exact shade to light/dark mode.
    static let palette: [(String, NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Grey", .systemGray),
    ]

    init(formatter: Formatter) {
        self.formatter = formatter
        self.styler = SelectionStyler(formatter: formatter)
        panel = ToolbarPanel(interactive: true)
        super.init()
        panel.contentView = buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelClosed),
                                               name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        func glassGroup(_ views: [NSView], spacing: CGFloat = 0) -> NSGlassEffectView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = spacing
            stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
            let glass = NSGlassEffectView()
            glass.contentView = stack
            groups.append((glass, stack))
            return glass
        }
        for popUp in [familyPopUp, facePopUp, sizePopUp, colorPopUp] {
            popUp.isBordered = false
            popUp.font = .systemFont(ofSize: 12)
            popUp.target = self
        }
        // Long family/face names truncate instead of stretching the toolbar.
        familyPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 104).isActive = true
        facePopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 92).isActive = true
        for popUp in [familyPopUp, facePopUp] {
            (popUp.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
            popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sizePopUp.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorPopUp.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let symbols: [(SelectionStyler.InlineStyleToggle, String)] = [
            (.bold, "bold"), (.italic, "italic"), (.underline, "underline"), (.strikethrough, "strikethrough")]
        var toggles: [NSView] = []
        for (style, symbol) in symbols {
            let b = FirstClickButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: style.rawValue)!,
                                     target: self, action: #selector(toggleStyle(_:)))
            b.isBordered = false
            b.setButtonType(.toggle)
            b.identifier = NSUserInterfaceItemIdentifier(style.rawValue)
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.toolTip = style.rawValue
            toggleButtons[style] = b
            toggles.append(b)
        }
        // Text glyphs rather than SF Symbols: the "minus" symbol draws much smaller than "plus".
        let minus = FirstClickButton(title: "\u{2212}", target: self, action: #selector(stepSize(_:)))
        let plus = FirstClickButton(title: "+", target: self, action: #selector(stepSize(_:)))
        for (b, tag) in [(minus, -1), (plus, 1)] {
            b.isBordered = false
            b.font = .systemFont(ofSize: 15, weight: .medium)
            b.tag = tag
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        }
        minus.toolTip = "Smaller"
        plus.toolTip = "Bigger"

        let fileLink = FirstClickButton(image: Self.folderLinkImage(), target: self, action: #selector(insertFileLink))
        fileLink.isBordered = false
        fileLink.contentTintColor = .labelColor
        fileLink.widthAnchor.constraint(equalToConstant: 28).isActive = true
        fileLink.toolTip = "Link to a file or folder in iCloud Drive (⌃⌘K)"

        equationPopUp.isBordered = false
        equationPopUp.font = .systemFont(ofSize: 14)
        equationPopUp.target = self
        equationPopUp.widthAnchor.constraint(equalToConstant: 34).isActive = true
        equationPopUp.toolTip = "Equation: switch text ↔ image (⌃⌘⇧E), copy as LaTeX or MathML"

        let glassViews = [
            glassGroup([familyPopUp, facePopUp], spacing: 0),
            glassGroup(toggles),
            glassGroup([minus, sizePopUp, plus]),
            glassGroup([colorPopUp]),
            glassGroup([fileLink]),
            glassGroup([equationPopUp]),
        ]
        equationGlass = glassViews.last
        container.controls = [familyPopUp, facePopUp, minus, sizePopUp, plus, colorPopUp, fileLink, equationPopUp]
            + toggles.compactMap { $0 as? NSControl }
        // The hints read each control's toolTip once; clearing it avoids a second, native tooltip
        // in the rare moments Pri Notes is active (e.g. with the colour panel open).
        for control in container.controls {
            guard let tip = control.toolTip else { continue }
            control.toolTip = nil
            hints.attach(to: control) { tip }
        }
        let row = NSView()
        glassViews.forEach(row.addSubview)
        container.spacing = Self.groupSpacing
        container.contentView = row
        layoutGroups()
        return container
    }

    /// Size each glass capsule to its controls and line them up. Laid out by hand: glass views don't
    /// report a fitting size from their content, so Auto Layout alone collapses them.
    @discardableResult
    private func layoutGroups() -> NSSize {
        let m = Self.outerMargin
        var x = m
        var height: CGFloat = 0
        let visible = groups.filter { !$0.glass.isHidden }
        for (_, stack) in visible { height = max(height, ceil(stack.fittingSize.height)) }
        height = max(height, 28)
        for (glass, stack) in visible {
            let width = ceil(stack.fittingSize.width)
            glass.frame = NSRect(x: x, y: m, width: width, height: height)
            glass.cornerRadius = height / 2          // capsule
            stack.frame = glass.bounds
            stack.autoresizingMask = [.width, .height]
            x += width + Self.groupSpacing
        }
        let size = NSSize(width: x - Self.groupSpacing + m, height: height + 2 * m)
        container.contentView?.frame = NSRect(origin: .zero, size: size)
        container.frame = NSRect(origin: .zero, size: size)
        return size
    }

    // MARK: Showing and hiding

    /// Called after keys/clicks in Notes: (re)schedule a check after a short pause.
    func update() {
        // Clicks on the toolbar itself (e.g. opening a menu) are not selection changes.
        if menuOpen || (panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)) { return }
        pending?.cancel()
        guard isEnabled else { return hide() }
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Re-read the selection's style after it was changed outside the toolbar (e.g. ⌘U).
    func styleChangedExternally() {
        if panel.isVisible { check(force: true) }
    }

    func escapePressed() {
        if panel.isVisible { dismissedSelection = selection; hide() }
    }

    func notesDeactivated() {
        if !colorSession { hide() }
    }

    func hide() {
        hints.hide()
        pending?.cancel()
        selection = nil
        panel.orderOut(nil)
    }

    /// Show, move or hide the toolbar for the current selection. The controls are only rebuilt when
    /// the selection changed or `force` is set (after applying a change).
    private func check(force: Bool = false) {
        guard !menuOpen else { return }
        guard isEnabled, !colorSession, let ctx = formatter.currentContext(), ctx.selection.length > 0 else { return hide() }
        let sel = ctx.selection
        if sel == dismissedSelection { return }
        dismissedSelection = nil
        let selectedText = ctx.text.substring(with: sel)
        let form = formatter.selectedEquationForm(in: ctx)
        let hasText = selectedText.contains(where: { !$0.isWhitespace && $0 != "\u{FFFC}" && $0 != "\u{200B}" })
        guard hasText || form == .image else { return hide() }

        guard let bounds = ctx.ax.bounds(of: ctx.element, range: sel) else { return hide() }
        if !force, panel.isVisible, sel == selection { return position(above: bounds) }
        if form == .image {
            // A selected image: only the ∑ capsule.
            for (glass, _) in groups { glass.isHidden = glass !== equationGlass }
        } else {
            let runs = styler.runs(in: sel, ax: ctx.ax, el: ctx.element)
            guard let summary = styler.summary(of: runs) else { return hide() }
            for (glass, _) in groups { glass.isHidden = glass === equationGlass && form == nil }
            refresh(with: summary)
        }
        selection = sel
        equationPopUp.menu = equationMenu(form: form)
        panel.setContentSize(layoutGroups())
        position(above: bounds)
        panel.orderFrontRegardless()
    }

    /// Centre the toolbar above the selection (AX rect, top-left origin); below it if no room.
    private func position(above rect: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let top = primary.frame.maxY - rect.minY
        let bottom = primary.frame.maxY - rect.maxY
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: top)) } ?? primary
        var origin = NSPoint(x: rect.midX - size.width / 2, y: top + 6)
        if origin.y + size.height > screen.visibleFrame.maxY { origin.y = bottom - size.height - 6 }
        origin.x = max(screen.visibleFrame.minX + 4, min(origin.x, screen.visibleFrame.maxX - size.width - 4))
        panel.setFrameOrigin(origin)
    }

    /// Debug: the toolbar content filled for `summary`, sized to fit (for `--toolbar-snapshot`).
    func debugContentView(for summary: SelectionStyler.Summary) -> NSView {
        refresh(with: summary)
        equationPopUp.menu = equationMenu(form: .text)
        for (glass, _) in groups { glass.isHidden = false }
        let view = panel.contentView!
        view.setFrameSize(layoutGroups())
        return view
    }

    // MARK: Filling the controls

    private func refresh(with s: SelectionStyler.Summary) {
        familyPopUp.menu = familyMenu(current: s.family)
        facePopUp.menu = faceMenu(family: s.family, current: s.face)
        facePopUp.isEnabled = s.family != nil
        sizePopUp.menu = sizeMenu(current: s.size)
        colorPopUp.menu = colorMenu(current: s.color)
        toggleButtons[.bold]?.state = s.bold ? .on : .off
        toggleButtons[.italic]?.state = s.italic ? .on : .off
        toggleButtons[.underline]?.state = s.underline ? .on : .off
        toggleButtons[.strikethrough]?.state = s.strikethrough ? .on : .off
        for b in toggleButtons.values { b.contentTintColor = b.state == .on ? .controlAccentColor : .labelColor }
    }

    /// Pull-down menus show their first item as the button title.
    private func titled(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        items.forEach(menu.addItem)
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ object: Any?, checked: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = object
        i.state = checked ? .on : .off
        return i
    }

    private func equationMenu(form: Formatter.EquationForm?) -> NSMenu {
        titled("∑", [
            item(form == .image ? "Switch to Text Equation  ($…$)" : "Switch to Image Equation  ($$…$$)",
                 #selector(switchEquationForm), nil),
            item("Copy LaTeX", #selector(copyEquation(_:)), "latex"),
            item("Copy MathML", #selector(copyEquation(_:)), "mathML"),
        ])
    }

    private func familyMenu(current: String?) -> NSMenu {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var items: [NSMenuItem] = []
        for family in Self.curatedFamilies where family == StyleSample.systemFamilyLabel || installed.contains(family) {
            let i = item(family, #selector(pickFamily(_:)), family, checked: family == current)
            let font = family == StyleSample.systemFamilyLabel ? NSFont.systemFont(ofSize: 13) : NSFont(name: family, size: 13)
            if let font { i.attributedTitle = NSAttributedString(string: family, attributes: [.font: font]) }
            items.append(i)
        }
        items.append(.separator())
        let all = NSMenuItem(title: "All Fonts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for family in NSFontManager.shared.availableFontFamilies.filter({ !$0.hasPrefix(".") }).sorted() {
            sub.addItem(item(family, #selector(pickFamily(_:)), family, checked: family == current))
        }
        all.submenu = sub
        items.append(all)
        return titled(current ?? "Mixed", items)
    }

    private func faceMenu(family: String?, current: String?) -> NSMenu {
        guard let family else { return titled("—", []) }
        var items: [NSMenuItem] = []
        if family == StyleSample.systemFamilyLabel {
            for italic in [false, true] {
                for (name, weight) in StyleSample.systemWeights {
                    let label = italic ? (name == "Regular" ? "Italic" : "\(name) Italic") : name
                    let i = item(label, #selector(pickSystemFace(_:)), [weight.rawValue, italic ? 1 : 0], checked: label == current)
                    i.attributedTitle = NSAttributedString(string: label, attributes:
                        [.font: StyleSample.systemFace(weight: weight, italic: italic, size: 13)])
                    items.append(i)
                }
                if !italic { items.append(.separator()) }
            }
        } else {
            for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
                guard let postScript = member[0] as? String, let face = member[1] as? String else { continue }
                let i = item(face, #selector(pickFace(_:)), postScript, checked: face == current)
                if let f = NSFont(name: postScript, size: 13) { i.attributedTitle = NSAttributedString(string: face, attributes: [.font: f]) }
                items.append(i)
            }
        }
        return titled(current ?? "Mixed", items)
    }

    private func sizeMenu(current: CGFloat?) -> NSMenu {
        let items = Self.sizes.map { size in
            item(Self.format(size), #selector(pickSize(_:)), size, checked: size == current)
        }
        return titled(current.map(Self.format) ?? "—", items)
    }

    private static func format(_ size: CGFloat) -> String {
        size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
    }

    private func colorMenu(current: NSColor??) -> NSMenu {
        var items: [NSMenuItem] = []
        let automatic = item("Automatic", #selector(pickColor(_:)), nil, checked: current == .some(nil))
        automatic.image = Self.swatch(nil)
        items.append(automatic)
        for (name, color) in Self.palette {
            let i = item(name, #selector(pickColor(_:)), color)
            i.image = Self.swatch(color)
            items.append(i)
        }
        items.append(.separator())
        items.append(item("More…", #selector(showColorPanel(_:)), nil))
        let menu = titled("", items)
        let head = menu.items[0]
        head.image = Self.swatch(current ?? nil, mixed: current == nil)
        return menu
    }

    /// The file-link button's icon: a chain link with a small folder in its empty top-left corner,
    /// so it reads as "link to an iCloud folder or file" and doesn't look like Notes' own Add Link.
    ///
    /// SF Symbols has no such glyph, so it is composed from `link` and `folder.fill` (both in every
    /// SF Symbols release, so fine on macOS 26). A halo around the folder is knocked out of the link
    /// so the two stay apart at small sizes. The result is a template image, tinted like the other
    /// toolbar icons.
    ///
    /// Example: `FirstClickButton(image: SelectionToolbar.folderLinkImage(), target: …, action: …)`.
    static func folderLinkImage(pointSize: CGFloat = 14) -> NSImage {
        let fallback = NSImage(systemSymbolName: "link", accessibilityDescription: "Link to file")!
        guard let link = fallback.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)),
              let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize * 0.58, weight: .bold))
        else { return fallback }
        let size = NSSize(width: link.size.width + folder.size.width * 0.3, height: link.size.height + folder.size.height * 0.25)
        let image = NSImage(size: size, flipped: false) { _ in
            link.draw(in: NSRect(x: size.width - link.size.width, y: 0, width: link.size.width, height: link.size.height))
            let badge = NSRect(x: 0, y: size.height - folder.size.height, width: folder.size.width, height: folder.size.height)
            let halo: CGFloat = 1.4
            for dx in stride(from: -halo, through: halo, by: halo / 2) {
                for dy in stride(from: -halo, through: halo, by: halo / 2) {
                    folder.draw(in: badge.offsetBy(dx: dx, dy: dy), from: .zero, operation: .destinationOut, fraction: 1)
                }
            }
            folder.draw(in: badge, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Link to an iCloud Drive file or folder"
        return image
    }

    /// Round colour swatch; nil = automatic (half light, half dark), `mixed` = hollow ring.
    static func swatch(_ color: NSColor?, mixed: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if mixed {
                NSColor.secondaryLabelColor.setStroke(); circle.lineWidth = 1.5; circle.stroke()
            } else if let color {
                color.setFill(); circle.fill()
            } else {
                NSColor.white.setFill(); circle.fill()
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                NSColor.black.setFill()
                NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.secondaryLabelColor.setStroke(); circle.lineWidth = 0.5; circle.stroke()
            }
            return true
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        hints.hide()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: Actions

    private func apply(_ change: SelectionStyler.Change) {
        menuOpen = false   // the action may arrive before menuDidClose
        guard let sel = selection else { return }
        styler.apply(change, to: sel)
        check(force: true)   // re-read the style and refresh the controls
    }

    @objc private func toggleStyle(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let style = SelectionStyler.InlineStyleToggle(rawValue: raw) else { return }
        apply(.toggle(style))
    }

    /// The picker takes focus from Notes, so the toolbar is hidden first; it reappears for the new selection.
    @objc private func insertFileLink() {
        hide()
        onInsertFileLink?()
    }

    @objc private func stepSize(_ sender: NSButton) { apply(.step(sender.tag)) }

    /// The equation is replaced, so the selection is gone: hide until the next selection.
    @objc private func switchEquationForm() {
        menuOpen = false
        hide()
        formatter.switchEquationForm()
    }

    @objc private func copyEquation(_ sender: NSMenuItem) {
        menuOpen = false
        guard let sel = selection else { return }
        formatter.copyEquation(sender.representedObject as? String == "mathML" ? .mathML : .latex)
        // Copying an image moves the cursor after it; put the selection back.
        if let ctx = formatter.currentContext() { ctx.ax.setSelectedRange(of: ctx.element, sel) }
    }

    @objc private func pickFamily(_ sender: NSMenuItem) {
        if let family = sender.representedObject as? String { apply(.family(family)) }
    }

    @objc private func pickFace(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { apply(.face(postScriptName: name)) }
    }

    @objc private func pickSystemFace(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [CGFloat], pair.count == 2 else { return }
        apply(.systemFace(weight: NSFont.Weight(pair[0]), italic: pair[1] != 0))
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let size = sender.representedObject as? CGFloat { apply(.size(size)) }
    }

    /// Palette colours are dynamic system colours, but Notes stores one fixed colour; the light-mode
    /// shade is used so the stored colour doesn't depend on the appearance when it was applied.
    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let dynamic = sender.representedObject as? NSColor else { return apply(.color(nil)) }
        var stored = dynamic
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            stored = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        apply(.color(stored))
    }

    /// "More…": the colour panel belongs to this app, so Notes goes to the background while it is
    /// open. The pick is applied when the panel closes (Notes is brought back to the front then).
    @objc private func showColorPanel(_ sender: NSMenuItem) {
        colorSession = true
        colorPanelPick = nil
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = false
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        colorPanelPick = sender.color
    }

    @objc private func colorPanelClosed(_ note: Notification) {
        guard colorSession else { return }
        colorSession = false
        NSColorPanel.shared.setTarget(nil)
        if let color = colorPanelPick { apply(.color(color)) }
    }
}
