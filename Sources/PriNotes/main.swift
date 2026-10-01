import AppKit
import PriNotesCore
import ServiceManagement

/// Menu-bar app: owns the key monitor, the formatter, and the settings menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = KeyMonitor()
    private let formatter = Formatter()
    private lazy var preview = LivePreview(formatter: formatter)
    private lazy var toolbar = SelectionToolbar(formatter: formatter)
    private lazy var fileLinks = FileLinkInserter(formatter: formatter)
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private let defaults = UserDefaults.standard

    /// (menu title, rule family, defaults key)
    private let ruleToggles: [(String, RuleSet, String)] = [
        ("Block formats  (# ## ### ``` [] >)", .blocks, "rules.blocks"),
        ("Inline formats  (**b** *i* __u__ ~~s~~ `code`)", .inline, "rules.inline"),
        ("Links  [text](url)", .links, "rules.links"),
        ("$…$  →  text equation", .unicodeMath, "rules.unicodeMath"),
        ("$$…$$  →  equation image", .renderedMath, "rules.renderedMath"),
        ("Smart symbols  (-> ≤ ≠ ± … ½)", .symbols, "rules.symbols"),
    ]

    /// (menu title, defaults key) for the math options.
    private let optionToggles: [(String, String)] = [
        ("Selection toolbar (font, style, size, colour)", "selectionToolbar"),
        ("Live equation preview", "livePreview"),
        ("Real superscripts/subscripts in $…$", "richScripts"),
        ("Equation images in display style", "displayStyle"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: ruleToggles.map { ($0.2, true) })
            .merging(["active": true, "displayStyle": false, "richScripts": true, "livePreview": true, "selectionToolbar": true]) { $1 })
        loadSettings()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.make()
            ?? NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Pri Notes")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onTrigger = { [weak self] in
            MainActor.assumeIsolated { self?.formatter.check(); self?.preview.update(); self?.toolbar.update() }
        }
        monitor.onActivity = { [weak self] in
            MainActor.assumeIsolated { self?.preview.update(); self?.toolbar.update() }
        }
        monitor.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.toolbar.escapePressed() }
        }
        monitor.onUnderlineShortcut = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let ctx = self.formatter.currentContext() else { return }
                if ctx.selection.length == 0 {
                    ctx.ax.pressMenuItem("Underline")          // no selection: Notes' typing-style toggle
                } else {
                    self.formatter.styler.apply(.toggle(.underline), to: ctx.selection)
                }
                self.toolbar.styleChangedExternally()
            }
        }
        monitor.onFileLinkHotkey = { [weak self] in
            MainActor.assumeIsolated { self?.toolbar.hide(); self?.fileLinks.run() }
        }
        toolbar.onInsertFileLink = { [weak self] in self?.fileLinks.run() }
        monitor.onHotkey = { [weak self] in
            MainActor.assumeIsolated {
                self?.formatter.toggleEquation()
                self?.preview.update()
            }
        }
        monitor.onSwitchFormHotkey = { [weak self] in
            MainActor.assumeIsolated {
                self?.toolbar.hide()
                self?.formatter.switchEquationForm()
            }
        }
        monitor.onNotesDeactivated = { [weak self] in
            MainActor.assumeIsolated { self?.preview.hide(); self?.toolbar.notesDeactivated() }
        }
        startWhenTrusted()
    }

    // MARK: - Accessibility permission

    private var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt once for Accessibility access, then poll until it is granted and start the tap.
    private func startWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary), monitor.start() { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isTrusted, self.monitor.start() else { return }
                timer.invalidate()
            }
        }
    }

    // MARK: - File links

    /// `shareddocuments://` links clicked in Notes (or anywhere else) arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == FileLinks.scheme { FileLinkOpener.open(url) }
    }

    // MARK: - Settings

    private func loadSettings() {
        var rules: RuleSet = []
        for (_, family, key) in ruleToggles where defaults.bool(forKey: key) { rules.insert(family) }
        formatter.enabled = rules
        formatter.isActive = defaults.bool(forKey: "active")
        formatter.renderer.displayStyle = defaults.bool(forKey: "displayStyle")
        formatter.richScripts = defaults.bool(forKey: "richScripts")
        preview.isEnabled = defaults.bool(forKey: "livePreview")
        if !preview.isEnabled { preview.hide() }
        toolbar.isEnabled = defaults.bool(forKey: "selectionToolbar")
        if !toolbar.isEnabled { toolbar.hide() }
    }

    // MARK: - Menu (rebuilt each time it opens so state is always current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Active", #selector(toggleActive), state: formatter.isActive))
        menu.addItem(.separator())
        for (index, (title, family, _)) in ruleToggles.enumerated() {
            let entry = item(title, #selector(toggleRule(_:)), state: formatter.enabled.contains(family))
            entry.tag = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for (index, (title, key)) in optionToggles.enumerated() {
            let entry = item(title, #selector(toggleOption(_:)), state: defaults.bool(forKey: key))
            entry.tag = index
            menu.addItem(entry)
        }
        let hint = NSMenuItem(title: "⌃⌘E  edit equation / insert equation now", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let switchHint = NSMenuItem(title: "⌃⌘⇧E  switch equation between text and image", action: nil, keyEquivalent: "")
        switchHint.isEnabled = false
        menu.addItem(switchHint)
        let linkHint = NSMenuItem(title: "⌃⌘K  link to an iCloud Drive file or folder", action: nil, keyEquivalent: "")
        linkHint.isEnabled = false
        menu.addItem(linkHint)
        if let error = formatter.lastError {
            menu.addItem(.separator())
            let e = NSMenuItem(title: "Last error: \(error)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          state: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Quit Pri Notes", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, state: Bool? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        if let state { i.state = state ? .on : .off }
        return i
    }

    @objc private func toggleActive() {
        defaults.set(!formatter.isActive, forKey: "active")
        loadSettings()
    }

    @objc private func toggleRule(_ sender: NSMenuItem) {
        let key = ruleToggles[sender.tag].2
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        loadSettings()
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        let key = optionToggles[sender.tag].1
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        loadSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Debug mode: `PriNotes --render '<latex>' out.png [fontSize] [--dark]` renders one equation
/// and exits, printing its size, the LaTeX read back from the PNG metadata, and the pixel hash.
@MainActor
func renderToFile(_ args: [String]) {
    guard args.count >= 3 else { print("usage: PriNotes --render '<latex>' out.png [fontSize] [--dark]"); exit(2) }
    let renderer = MathRenderer()
    Task { @MainActor in
        do {
            let size = args.count > 3 ? CGFloat(Double(args[3]) ?? 13) : 13
            let eq = try await renderer.render(args[1], fontSize: size, dark: args.contains("--dark"))
            try eq.png.write(to: URL(fileURLWithPath: args[2]))
            print("wrote \(args[2]) — \(Int(eq.size.width))×\(Int(eq.size.height)) pt")
            print("embedded source: \(MathRenderer.embeddedSource(in: eq.png) ?? "none")")
            print("pixel hash: \(MathRenderer.pixelHash(of: eq.png) ?? "none")")
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
    NSApplication.shared.run()
}

/// Debug mode: `PriNotes --preview-snapshot '<latex>' out.png [--dark]` draws the live-preview
/// panel content (on a mid-grey backdrop, since the blur material can't be captured) and exits.
@MainActor
func previewSnapshot(_ args: [String]) {
    guard args.count >= 3 else { print("usage: PriNotes --preview-snapshot '<latex>' out.png [--dark]"); exit(2) }
    let dark = args.contains("--dark")
    NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let renderer = MathRenderer()
    Task { @MainActor in
        let (image, caption) = await LivePreview.render(args[1], caption: LivePreview.caption(display: false),
                                                        dark: dark, with: renderer)
        let view = PreviewContentView(frame: .zero)
        let size = view.configure(image: image, caption: caption)
        let margin: CGFloat = 10
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        view.setFrameOrigin(NSPoint(x: margin, y: margin))
        backdrop.addSubview(view)
        let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        print("panel \(Int(size.width))×\(Int(size.height)) pt, image \(image.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none"), caption: \(caption)")
        exit(0)
    }
    NSApplication.shared.run()
}

/// Debug mode: `PriNotes --mathml '<latex>' [--display]` prints the MathML that the ∑ menu's
/// Copy MathML would put on the clipboard, and exits.
@MainActor
func printMathML(_ args: [String]) {
    guard args.count >= 2 else { print("usage: PriNotes --mathml '<latex>' [--display]"); exit(2) }
    let renderer = MathRenderer()
    Task { @MainActor in
        do {
            print(try await renderer.mathML(args[1], display: args.contains("--display")))
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
    NSApplication.shared.run()
}

/// Debug mode: `PriNotes --network-test` tries to reach the internet from inside the equation
/// renderer (fetch, image, script) and prints whether each attempt was blocked. Exit 0 = all blocked.
@MainActor
func networkTest() {
    let renderer = MathRenderer()
    Task { @MainActor in
        let results = await renderer.networkProbe()
        results.forEach { print($0) }
        // Rendering must still work with the lockdown in place.
        let rendered = (try? await renderer.render("E = mc^2", fontSize: 13, dark: false)) != nil
        print("render still works: \(rendered)")
        let leaked = results.contains { $0.contains("REACHED") || $0.contains("LOADED") }
        exit(!leaked && rendered ? 0 : 1)
    }
    NSApplication.shared.run()
}

/// Debug mode: `PriNotes --menubar-icon out.png [pointSize]` renders the menu-bar icon (black on white).
@MainActor
func renderMenuBarIcon(_ args: [String]) -> Never {
    let size = args.count > 2 ? CGFloat(Double(args[2]) ?? 15) : 15
    guard args.count >= 2, let icon = MenuBarIcon.make(pointSize: size) else { print("usage: --menubar-icon out.png [pt]"); exit(2) }
    let scale: CGFloat = 4
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width * scale), pixelsHigh: Int(icon.size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    icon.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
    print("icon \(icon.size.width)×\(icon.size.height) pt → \(args[1])")
    exit(0)
}

/// Debug mode: `PriNotes --recover-from-clipboard` runs the ⌃⌘E image-recovery code on whatever is
/// on the clipboard now (copy an equation image in Notes first) and prints the LaTeX it finds.
@MainActor
func recoverFromClipboard() -> Never {
    let source = Formatter.equationSource(on: NSPasteboard.general, store: EquationStore())
    print(source.map { "recovered: \($0)" } ?? "no source found (see ~/Library/Logs/PriNotes.log)")
    exit(source == nil ? 1 : 0)
}

/// Debug mode: `PriNotes --toolbar-snapshot out.png [--dark]` draws the selection toolbar's controls
/// (on a grey backdrop; the glass material itself only renders on screen) and exits.
@MainActor
func toolbarSnapshot(_ args: [String]) -> Never {
    NSApplication.shared.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
    let toolbar = SelectionToolbar(formatter: Formatter())
    let summary = SelectionStyler.Summary(family: "Palatino", face: "Bold Italic", size: 13, bold: true, italic: true,
                                          underline: false, strikethrough: false, color: .some(NSColor.systemBlue))
    let content = toolbar.debugContentView(for: summary)
    let margin: CGFloat = 12
    let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: content.frame.width + 2 * margin, height: content.frame.height + 2 * margin))
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
    content.setFrameOrigin(NSPoint(x: margin, y: margin))
    backdrop.addSubview(content)
    let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
    print("toolbar \(Int(content.frame.width))×\(Int(content.frame.height)) pt → \(args[1])")
    exit(0)
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--network-test") { networkTest() }
    if let i = CommandLine.arguments.firstIndex(of: "--mathml") { printMathML(Array(CommandLine.arguments[i...])) }
    if let i = CommandLine.arguments.firstIndex(of: "--toolbar-snapshot") { toolbarSnapshot(Array(CommandLine.arguments[i...])) }
    if let i = CommandLine.arguments.firstIndex(of: "--notes-lab") {
        let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : NSTemporaryDirectory() + "notes-lab.txt"
        NotesLab.run(reportPath: path)
    }
    if CommandLine.arguments.contains("--recover-from-clipboard") { recoverFromClipboard() }
    if let i = CommandLine.arguments.firstIndex(of: "--menubar-icon") { renderMenuBarIcon(Array(CommandLine.arguments[i...])) }
    if let i = CommandLine.arguments.firstIndex(of: "--preview-snapshot") {
        previewSnapshot(Array(CommandLine.arguments[i...]))
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render") {
        renderToFile(Array(CommandLine.arguments[i...]))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
