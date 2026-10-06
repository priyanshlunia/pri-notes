import AppKit

/// A small Liquid Glass capsule pinned to the bottom-right corner of the note in Notes:
/// `[ ↰ 2 | 📋 ]`
///
/// - **Backlinks** (`arrow.turn.up.left`, with a count): a menu of the notes that link to this
///   one with `>>` links, read from Notes' database (`NotesDatabase`, needs Full Disk Access).
///   Picking one opens it through Notes' own `applenotes://showNote?identifier=…` link.
/// - **Copy as Markdown** (`doc.on.clipboard`): `MarkdownExporter`, equations as LaTeX. The icon
///   turns into a checkmark for a moment when the clipboard holds the result.
///
/// It is shown while Notes is frontmost and its focused window shows a note, and follows the note
/// editor (the "Note Body Scroll View") when the window moves, resizes or the sidebar changes:
/// window moves and resizes are requested as AX notifications on Notes' application element, and a
/// 0.25 s check, running only while Notes is frontmost, catches everything else (and the moves, if
/// Notes doesn't post them there). The note shown comes from the editor's AX
/// identifier `Note[id=<UUID>]`, which is the note's id in the database and in links.
///
/// The panel reuses the selection toolbar's never-key, first-click panel and its macOS 26 hit
/// testing (`ToolbarGlassContainer`).
@MainActor
final class NoteFooter: NSObject, NSMenuDelegate {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }   // loadSettings() re-assigns it on every menu toggle
            isEnabled ? notesActivated() : stop()
        }
    }

    private let exporter: MarkdownExporter
    private let panel: ToolbarPanel
    private let container = ToolbarGlassContainer()
    private let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private let backlinksButton = FirstClickButton()
    private let exportButton = FirstClickButton()
    /// Hover notes: AppKit tooltips never show for a background app (see HoverHint).
    private let hints = HoverHint()
    /// Set from the measured count: AppKit under-reports a borderless image + title button's width,
    /// which clipped "12" to "1".
    private var backlinksWidth: NSLayoutConstraint!

    private var ax: NotesAX?
    private var observer: AXObserver?
    private var timer: Timer?
    /// The note editor being followed, and the note it shows.
    private var editor: (scrollArea: AXUIElement, textArea: AXUIElement, window: AXUIElement)?
    private var noteID: String?
    /// After a search finds no editor (gallery view, Settings), don't search again until then:
    /// the search walks up to 400 AX elements on the main thread.
    private var nextEditorSearch = Date.distantPast
    private var lastLookup: NotesDatabase.Lookup?
    private var menuOpen = false
    private var restoreExportIcon: DispatchWorkItem?
    private let databaseQueue = DispatchQueue(label: "local.prinotes.notes-database")

    private static let backlinksSymbol = "arrow.turn.up.left"
    private static let exportSymbol = "doc.on.clipboard"
    private static let outerMargin: CGFloat = 6     // room for the glass shadow
    /// Distance from the editor's right edge (clear of its scroller) and bottom edge.
    private static let rightInset: CGFloat = 18
    private static let bottomInset: CGFloat = 12

    init(formatter: Formatter) {
        exporter = MarkdownExporter(formatter: formatter)
        panel = ToolbarPanel(interactive: true)
        super.init()
        panel.contentView = buildContent()
        setBacklinkCount(nil)
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        backlinksButton.image = NSImage(systemSymbolName: Self.backlinksSymbol, accessibilityDescription: "Backlinks")?
            .withSymbolConfiguration(symbolConfig)
        backlinksButton.imagePosition = .imageLeading
        backlinksButton.font = .systemFont(ofSize: 12, weight: .medium)
        backlinksButton.target = self
        backlinksButton.action = #selector(showBacklinks)

        exportButton.image = Self.exportImage()
        exportButton.imagePosition = .imageOnly
        exportButton.target = self
        exportButton.action = #selector(copyAsMarkdown)

        for button in [backlinksButton, exportButton] {
            button.isBordered = false
            button.contentTintColor = .labelColor
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        exportButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        backlinksWidth = backlinksButton.widthAnchor.constraint(equalToConstant: 24)
        backlinksWidth.isActive = true

        stack.setViews([backlinksButton, exportButton], in: .leading)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        glass.contentView = stack
        let row = NSView()
        row.addSubview(glass)
        container.contentView = row
        container.controls = [backlinksButton, exportButton]
        hints.attach(to: backlinksButton) { [weak self] in self?.backlinksHint() ?? "" }
        hints.attach(to: exportButton) { "Copy this note as Markdown, equations as LaTeX" }
        layout()
        return container
    }

    /// Size the capsule to its buttons (glass views don't report a fitting size, see SelectionToolbar).
    @discardableResult
    private func layout() -> NSSize {
        let m = Self.outerMargin
        let fitting = stack.fittingSize
        let height = max(28, ceil(fitting.height))
        glass.frame = NSRect(x: m, y: m, width: ceil(fitting.width), height: height)
        glass.cornerRadius = height / 2
        stack.frame = glass.bounds
        stack.autoresizingMask = [.width, .height]
        let size = NSSize(width: glass.frame.width + 2 * m, height: height + 2 * m)
        container.contentView?.frame = NSRect(origin: .zero, size: size)
        container.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        return size
    }

    /// What the backlinks button's hover note says, for the current lookup.
    private func backlinksHint() -> String {
        switch lastLookup {
        case .links(let links) where links.count == 1: return "Linked from 1 note: click to see it"
        case .links(let links) where links.count > 1: return "Linked from \(links.count) notes: click to see them"
        case .noAccess: return "Backlinks: needs Full Disk Access (click for details)"
        default: return "Backlinks: notes that link to this one"
        }
    }

    private static func exportImage() -> NSImage? {
        NSImage(systemSymbolName: exportSymbol, accessibilityDescription: "Copy as Markdown")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// Show the number of backlinks next to the icon (nothing for none or unknown).
    private func setBacklinkCount(_ lookup: NotesDatabase.Lookup?) {
        lastLookup = lookup
        switch lookup {
        case .links(let links) where !links.isEmpty:
            backlinksButton.title = "\(links.count)"
        default:
            backlinksButton.title = ""
        }
        let imageWidth = backlinksButton.image?.size.width ?? 16
        let titleWidth = backlinksButton.title.isEmpty ? 0
            : ceil((backlinksButton.title as NSString).size(withAttributes: [.font: backlinksButton.font!]).width) + 4
        backlinksWidth.constant = max(24, ceil(imageWidth) + 8 + titleWidth)
        layout()
        if let editor, let frame = ax?.frame(of: editor.scrollArea) { position(in: frame) }
    }

    // MARK: Following the note editor

    /// Notes came to the front: start following its editor.
    func notesActivated() {
        guard isEnabled, NotesAX.isFrontmost, let notes = NotesAX.runningApp else { return }
        if ax?.pid != notes.processIdentifier {
            ax = NotesAX(pid: notes.processIdentifier)
            editor = nil
            observe(pid: notes.processIdentifier)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        noteID = nil   // re-read the backlinks: links may have changed meanwhile
        nextEditorSearch = .distantPast
        tick()
    }

    func notesDeactivated() {
        if menuOpen { return }
        stop()
    }

    /// A key or click in Notes: the note shown may have changed.
    func update() {
        if timer != nil { tick() }
    }

    private func stop() {
        hints.hide()
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    /// Window moves and resizes, delivered as soon as Notes reports them.
    private func observe(pid: pid_t) {
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        observer = nil
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let footer = Unmanaged<NoteFooter>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { footer.update() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    /// Find (or re-check) the editor, move the capsule to its corner and notice note switches.
    private func tick() {
        guard !menuOpen else { return }
        guard isEnabled, NotesAX.isFrontmost, let ax else {
            return stop()   // also ends the timer, e.g. when Notes went away while the menu was open
        }
        // The cached editor is kept while it still belongs to the focused window.
        let stillShown = editor.map { current in
            ax.focusedWindow().map { CFEqual($0, current.window) } == true && ax.frame(of: current.scrollArea) != nil
        } ?? false
        if !stillShown {
            editor = Date() >= nextEditorSearch ? ax.noteEditor() : nil
            if editor == nil { nextEditorSearch = Date().addingTimeInterval(1) }
        }
        guard let editor, let frame = ax.frame(of: editor.scrollArea), frame.width > 200, frame.height > 120 else {
            return panel.orderOut(nil)
        }
        let id = ax.noteIdentifier(of: editor.textArea)
        if id != noteID {
            noteID = id
            refreshBacklinks()
        }
        position(in: frame)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Bottom-right corner of the editor (AX rect, top-left origin).
    private func position(in rect: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let size = panel.frame.size
        let m = Self.outerMargin
        let origin = NSPoint(x: rect.maxX - Self.rightInset - size.width + m,
                             y: primary.frame.maxY - rect.maxY + Self.bottomInset - m)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// Count the backlinks in the background; the result is used only if the note hasn't changed.
    private func refreshBacklinks() {
        guard let id = noteID else { return setBacklinkCount(nil) }
        databaseQueue.async { [weak self] in
            let lookup = NotesDatabase.backlinks(to: id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.noteID == id else { return }
                    if case .failed(let message) = lookup, self.lastLookup != lookup { Log.write("backlinks: \(message)") }
                    self.setBacklinkCount(lookup)
                }
            }
        }
    }

    // MARK: Backlinks menu

    @objc private func showBacklinks() {
        hints.hide()
        guard let id = noteID else { return NSSound.beep() }
        // Fresh, and on the main thread: a few milliseconds. Notes' store is in WAL mode, where a
        // reader never waits for a writer.
        let lookup = NotesDatabase.backlinks(to: id)
        setBacklinkCount(lookup)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        func note(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        switch lookup {
        case .links(let links) where links.isEmpty:
            menu.addItem(.sectionHeader(title: "Backlinks"))
            note("No notes link to this note")
            note("Link to it from another note with >>")
        case .links(let links):
            menu.addItem(.sectionHeader(title: "Linked from \(links.count) note\(links.count == 1 ? "" : "s")"))
            for link in links {
                let item = NSMenuItem(title: link.title, action: #selector(openBacklink(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = link.url
                item.subtitle = link.folder
                item.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
                menu.addItem(item)
            }
        case .noAccess:
            menu.addItem(.sectionHeader(title: "Backlinks"))
            note("Pri Notes needs Full Disk Access to read")
            note("Notes' links (read-only, offline).")
            menu.addItem(.separator())
            let open = NSMenuItem(title: "Open Full Disk Access Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        case .failed(let message):
            Log.write("backlinks: \(message)")
            menu.addItem(.sectionHeader(title: "Backlinks"))
            note("Couldn't read Notes' links (see PriNotes.log)")
        }

        // Above the capsule, right-aligned with it.
        let button = backlinksButton
        guard let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = menu.size
        menu.popUp(positioning: nil, at: NSPoint(x: rect.maxX - size.width + 8, y: glassTop() + 6 + size.height), in: nil)
    }

    /// Top of the glass capsule in screen coordinates.
    private func glassTop() -> CGFloat {
        panel.frame.maxY - Self.outerMargin
    }

    @objc private func openBacklink(_ sender: NSMenuItem) {
        menuOpen = false
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPrivacySettings() {
        menuOpen = false
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    // MARK: Copy as Markdown

    @objc private func copyAsMarkdown() {
        hints.hide()
        guard exporter.copyNote(textArea: editor?.textArea, ax: ax) else { return }
        exportButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        exportButton.contentTintColor = .controlAccentColor
        restoreExportIcon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.exportButton.image = Self.exportImage()
            self?.exportButton.contentTintColor = .labelColor
        }
        restoreExportIcon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    // MARK: Debug

    /// The capsule's content for `--footer-snapshot`, with `count` backlinks.
    func debugContentView(count: Int) -> NSView {
        let fake = (0..<count).map { NotesDatabase.Backlink(identifier: "\($0)", title: "Note \($0)", folder: nil) }
        setBacklinkCount(count > 0 ? .links(fake) : nil)
        return panel.contentView!
    }
}
