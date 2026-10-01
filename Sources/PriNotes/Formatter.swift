import AppKit
import PriNotesCore

/// Turns a detected `Action` into edits of the focused Apple Notes text view.
///
/// Strategy per action:
/// - block:        delete the "## " marker via AX, then press Format ▸ Heading (etc.).
/// - inline:       replace "**x**" with "x" via AX, select "x", press Format ▸ Font ▸ Bold,
///                 collapse the cursor to the end and press Bold again so new typing is plain.
/// - code / link:  paste an RTF snippet (monospaced text or a link, followed by a plain space)
///                 over the Markdown source, then restore the user's clipboard.
/// - unicodeMath:  replace "$…$" with the text of `LatexUnicode.convertRich`, then apply
///                 Format ▸ Font ▸ Baseline ▸ Superscript/Subscript to the script runs
///                 (or, with rich scripts off, insert `LatexUnicode.convert` as plain text).
/// - renderedMath: typeset asynchronously with MathJax (ink matched to light/dark mode,
///                 transparent background) and paste the PNG over "$$…$$".
///
/// Every math conversion is recorded in `EquationStore`, which `toggleEquation()` (⌃⌘E) uses to
/// turn a converted equation back into editable `$source` text.
@MainActor
final class Formatter {
    var enabled: RuleSet = .all
    var isActive = true
    /// Use Notes' real superscript/subscript formatting for `$…$` scripts (vs Unicode ²/₁ characters).
    var richScripts = true
    /// Human-readable description of the most recent failure (shown in the menu).
    private(set) var lastError: String?

    let renderer = MathRenderer()
    let store = EquationStore()
    /// Applies fonts via Paste Style; shared mechanism with the selection toolbar.
    lazy var styler = SelectionStyler(formatter: self)
    private var ax: NotesAX?
    /// True while we are editing, so our own edits never re-trigger detection.
    private var isBusy = false
    /// The unclosed `$…`/`$$…` being edited: where its delimiter starts, and the text that followed
    /// it on the line when editing began. See `editingSpan(in:at:)`.
    private var editTail: (start: Int, tail: String)?

    private static let attachmentCharacter: unichar = 0xFFFC
    /// Invisible separator placed after text equations so later typing uses the body font.
    static let zeroWidthSpace = "\u{200B}"

    // Format-menu item titles in Notes (English UI) and fallback shortcuts.
    private static let blockMenuTitle: [BlockStyle: String] = [
        .title: "Title", .heading: "Heading", .subheading: "Subheading",
        .monostyled: "Monostyled", .checklist: "Checklist", .blockQuote: "Block Quote",
    ]
    private static let blockShortcut: [BlockStyle: (CGKeyCode, CGEventFlags)] = [
        .title: (17, [.maskCommand, .maskShift]),        // ⇧⌘T
        .heading: (4, [.maskCommand, .maskShift]),       // ⇧⌘H
        .subheading: (38, [.maskCommand, .maskShift]),   // ⇧⌘J
        .monostyled: (46, [.maskCommand, .maskShift]),   // ⇧⌘M
        .checklist: (37, [.maskCommand, .maskShift]),    // ⇧⌘L
        .blockQuote: (39, [.maskCommand]),               // ⌘'
    ]
    private static let inlineMenuTitle: [InlineStyle: String] = [
        .bold: "Bold", .italic: "Italic", .underline: "Underline", .strikethrough: "Strikethrough",
    ]
    private static let inlineShortcut: [InlineStyle: (CGKeyCode, CGEventFlags)] = [
        .bold: (11, [.maskCommand]), .italic: (34, [.maskCommand]), .underline: (32, [.maskCommand]),
    ]
    private static let superscriptPath = ["Baseline", "Superscript"]
    private static let subscriptPath = ["Baseline", "Subscript"]
    private static let baselineResetPath = ["Baseline", "Use Default"]

    // MARK: - Context

    struct Context {
        let ax: NotesAX
        let element: AXUIElement
        let text: NSString
        let selection: NSRange
    }

    /// The focused Notes text area with its text and selection, or nil if Notes isn't in front.
    func currentContext() -> Context? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == NotesAX.bundleID else { return nil }
        if ax?.pid != app.processIdentifier { ax = NotesAX(pid: app.processIdentifier) }
        guard let ax, let el = ax.focusedTextArea(),
              let text = ax.value(of: el), let sel = ax.selectedRange(of: el) else { return nil }
        // The value and the selection are two separate AX reads, so while Notes is switching notes
        // or reflowing they can disagree (seen: selection {1008, 4} against a 873-unit value).
        // Every caller slices `text` with `sel`, which raises an uncatchable ObjC exception.
        guard NSMaxRange(sel) <= text.length else { return nil }
        return Context(ax: ax, element: el, text: text, selection: sel)
    }

    private var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Entry points

    /// Called after every trigger keystroke in Notes.
    func check() {
        guard isActive, !isBusy, let ctx = currentContext(), ctx.selection.length == 0,
              let action = Rules.detect(in: ctx.text, cursor: ctx.selection.location, enabled: enabled) else { return }
        let (ax, el) = (ctx.ax, ctx.element)

        // Leave Markdown-looking text alone inside monostyled (code) paragraphs.
        if case .block(.monostyled, _) = action {} else if isMonospaced(ax, el, at: ctx.selection.location - 1) { return }

        isBusy = true
        defer { isBusy = false }
        switch action {
        case let .block(style, prefixRange):
            applyBlock(style, prefixRange: prefixRange, ax: ax, el: el)
        case let .inline(style, matchRange, inner):
            applyInline(style, matchRange: matchRange, inner: inner, ax: ax, el: el)
        case let .code(matchRange, inner):
            // Same mechanism as text math: insert through AX (keeps the typed text's style), then
            // Paste Style Menlo onto the code, keeping its colour; the trailing space keeps your font.
            let context = styler.runs(in: NSRange(location: matchRange.location, length: 1), ax: ax, el: el).first?.style
            let size = context?.font.pointSize ?? ax.fontSize(of: el, at: matchRange.location)
            guard ax.replace(in: el, range: matchRange, with: inner + " ") else { return fail("Couldn't edit the note text.") }
            let codeRange = NSRange(location: matchRange.location, length: (inner as NSString).length)
            let menlo = NSFont(name: "Menlo-Regular", size: size) ?? NSFont.userFixedPitchFont(ofSize: size)!
            if !styler.pasteStyles([(codeRange, CharacterStyle(font: menlo, color: context?.color), true)], ax: ax, el: el) {
                fail("Format ▸ Font ▸ Paste Style is unavailable in Notes.")
            }
            ax.setSelectedRange(of: el, NSRange(location: NSMaxRange(codeRange) + 1, length: 0))
        case let .link(matchRange, text, url):
            pasteLink(text: text, url: URL(string: url) ?? url, over: matchRange, trailingSpace: true, ax: ax, el: el)
        case let .unicodeMath(matchRange, latex):
            insertTextMath(latex: latex, over: matchRange, ax: ax, el: el)
        case let .renderedMath(matchRange, latex):
            startRenderedMath(latex: latex, over: matchRange, text: ctx.text, ax: ax, el: el)
        }
    }

    /// The math span the cursor is in, for the live preview and ⌃⌘E.
    ///
    /// An unclosed span would otherwise run to the end of the line, so editing an equation in the
    /// middle of a sentence would treat the rest of the sentence as LaTeX. Instead, the text that
    /// followed the cursor when the edit began (or, after ⌃⌘E reopens an equation, the text that
    /// followed the equation) is remembered and kept outside the span (`MathSpans.trimmed`).
    ///
    /// Example: reopening the equation in "so x² is small." gives "so $x^2 is small." with the
    /// tail " is small." remembered, so the span's source is "x^2" wherever the cursor is inside it.
    func editingSpan(in text: NSString, at cursor: Int) -> MathSpan? {
        guard let span = MathSpans.span(in: text, at: cursor) else { editTail = nil; return nil }
        if span.closed { editTail = nil; return span }
        if let remembered = editTail, remembered.start == span.fullRange.location,
           let cut = MathSpans.trimmed(span, in: text, keepingOutside: remembered.tail) {
            // The cursor may have moved into the remembered tail, which isn't part of the equation.
            return cursor <= NSMaxRange(cut.sourceRange) ? cut : nil
        }
        // A new edit: everything after the cursor on this line stays outside the equation.
        let lineEnd = NSMaxRange(span.fullRange)
        let tail = text.substring(with: NSRange(location: cursor, length: lineEnd - cursor))
        editTail = (span.fullRange.location, tail)
        return MathSpans.trimmed(span, in: text, keepingOutside: tail)
    }

    /// ⌃⌘E. Inside a `$…`/`$$…` span: convert it now. On a converted equation (cursor right after
    /// it, or equation selected): turn it back into `$source` / `$$source` for editing.
    func toggleEquation() {
        guard isActive, !isBusy, let ctx = currentContext() else { return }
        let (ax, el, text, sel) = (ctx.ax, ctx.element, ctx.text, ctx.selection)

        // 1. Commit an equation being typed or edited.
        if sel.length == 0, let span = editingSpan(in: text, at: sel.location) {
            let range = span.fullRange
            let source = text.substring(with: span.sourceRange).trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { return }
            isBusy = true
            defer { isBusy = false }
            if span.display { startRenderedMath(latex: source, over: range, text: text, ax: ax, el: el) }
            else { insertTextMath(latex: source, over: range, ax: ax, el: el) }
            return
        }

        // 2. An equation image: selected, or immediately before the cursor.
        var imageRange: NSRange?
        if sel.length == 1, text.character(at: sel.location) == Formatter.attachmentCharacter {
            imageRange = sel
        } else if sel.length == 0, sel.location > 0, text.character(at: sel.location - 1) == Formatter.attachmentCharacter {
            imageRange = NSRange(location: sel.location - 1, length: 1)
        }
        if let imageRange {
            isBusy = true
            defer { isBusy = false }
            guard let source = sourceOfImage(at: imageRange, ax: ax, el: el) else {
                return fail("No LaTeX source found for this image (only equations made by Pri Notes can be edited).")
            }
            reopen(source: "$$" + source, over: imageRange, text: text, ax: ax, el: el)
            return
        }

        // 3. A Unicode/rich-text equation: selected, or just before the cursor.
        // Text equations end in an invisible zero-width space (see insertTextMath); include it in
        // the range being replaced but ignore it when matching. The cursor can sit on either side
        // of it, since it has no width.
        var entry: EquationStore.Entry?
        var range = sel
        if sel.length > 0 {
            entry = store.source(forText: text.substring(with: sel).replacingOccurrences(of: Formatter.zeroWidthSpace, with: ""))
        } else {
            let zwsp = Formatter.zeroWidthSpace
            var end = sel.location          // end of the equation's own text
            var replaceEnd = sel.location   // end of what gets replaced (includes the marker)
            var hasMarker = false
            if end > 0, text.substring(with: NSRange(location: end - 1, length: 1)) == zwsp {
                end -= 1
                hasMarker = true
            } else if sel.location < text.length, text.substring(with: NSRange(location: sel.location, length: 1)) == zwsp {
                replaceEnd += 1
                hasMarker = true
            }
            let prefix = text.substring(to: end)
            // With the marker, the text before it is known to be an equation, so any equation in the
            // history may match. Without it, only the latest, so a short result like "x" can't be
            // confused with ordinary text.
            let found = hasMarker
                ? store.unicodeEntry(endingAt: prefix)
                : store.latestUnicodeEntry(endingAt: prefix)
            if let found, let t = found.text {
                entry = found
                let start = end - (t as NSString).length
                range = NSRange(location: start, length: replaceEnd - start)
            }
        }
        guard let entry else {
            return fail("Put the cursor right after an equation (or select it), then press ⌃⌘E.")
        }
        isBusy = true
        defer { isBusy = false }
        reopen(source: "$" + entry.source, over: range, text: text, ax: ax, el: el)
    }

    // MARK: - Markdown actions

    private func applyBlock(_ style: BlockStyle, prefixRange: NSRange, ax: NotesAX, el: AXUIElement) {
        guard ax.replace(in: el, range: prefixRange, with: "") else { return fail("Couldn't edit the note text.") }
        if !ax.pressMenuItem(Formatter.blockMenuTitle[style]!), let (key, flags) = Formatter.blockShortcut[style] {
            ax.postKey(key, flags: flags)
        }
    }

    private func applyInline(_ style: InlineStyle, matchRange: NSRange, inner: String, ax: NotesAX, el: AXUIElement) {
        guard ax.replace(in: el, range: matchRange, with: inner) else { return fail("Couldn't edit the note text.") }
        let innerLength = (inner as NSString).length
        ax.setSelectedRange(of: el, NSRange(location: matchRange.location, length: innerLength))
        toggle(style, ax: ax)
        // With an empty selection the same command toggles the *typing* style, so text typed
        // next is not bold/italic/….
        ax.setSelectedRange(of: el, NSRange(location: matchRange.location + innerLength, length: 0))
        toggle(style, ax: ax)
    }

    private func toggle(_ style: InlineStyle, ax: NotesAX) {
        if ax.pressMenuItem(Formatter.inlineMenuTitle[style]!) { return }
        if let (key, flags) = Formatter.inlineShortcut[style] { ax.postKey(key, flags: flags) }
        else { fail("Format ▸ Font ▸ \(Formatter.inlineMenuTitle[style]!) not found in Notes.") }
    }

    // MARK: - Math

    /// Replace `range` with the converted text of `latex` typeset like LaTeX — Palatino Italic for
    /// variables, Palatino Roman for \mathrm, function names, digits and operators — then format
    /// script runs as real superscripts/subscripts, and remember the source for re-editing.
    ///
    /// How it's inserted (no clipboard involved):
    /// 1. The `$…$` source is replaced through Accessibility with the plain equation text plus a
    ///    zero-width space. Inserted text takes the style of what it replaces — the text you typed —
    ///    so the equation starts out in your colour and size, and the zero-width space keeps your font
    ///    so the text typed next continues in it.
    /// 2. Each run gets Palatino (Italic or Roman) in that colour and size with Paste Style
    ///    (`SelectionStyler.pasteStyles`, the same mechanism as the selection toolbar).
    /// 3. Script runs get Format ▸ Font ▸ Baseline ▸ Superscript/Subscript.
    ///
    /// (Earlier versions pasted rich text with Edit ▸ Paste and Retain Style. Notes enables that item
    /// based on a stale view of the clipboard, so the press was often silently ignored.)
    private func insertTextMath(latex: String, over range: NSRange, ax: NotesAX, el: AXUIElement) {
        // A marker from an earlier equation can end up inside a new span (e.g. "$" typed around
        // converted text). It isn't LaTeX, so keep it out of the source and the history.
        let latex = latex.replacingOccurrences(of: Formatter.zeroWidthSpace, with: "")
        let runs = LatexUnicode.convertRich(latex, unicodeScripts: !richScripts)
        let plain = runs.map(\.text).joined()
        // The typed "$" carries the style of the surrounding text.
        let context = styler.runs(in: NSRange(location: range.location, length: 1), ax: ax, el: el).first?.style
        let size = context?.font.pointSize ?? ax.fontSize(of: el, at: max(0, range.location - 1))
        let color = context?.color
        let roman = NSFont(name: "Palatino-Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        let italic = NSFont(name: "Palatino-Italic", size: size) ?? roman

        guard ax.replace(in: el, range: range, with: plain + Formatter.zeroWidthSpace) else {
            return fail("Couldn't edit the note text.")
        }
        // Scripts first: Notes' Superscript/Subscript shifts the text *and* shrinks it (~0.83×), so it
        // must come before the sizes are set, or the two would compound (measured 58 % instead of 70 %).
        var offset = range.location
        for run in runs {
            let length = (run.text as NSString).length
            if run.level != 0 {
                ax.setSelectedRange(of: el, NSRange(location: offset, length: length))
                let path = run.level > 0 ? Formatter.superscriptPath : Formatter.subscriptPath
                for _ in 0..<abs(run.level) {
                    if !ax.pressMenuItem(path: path) { fail("Format ▸ Font ▸ Baseline ▸ \(path[1]) not found in Notes."); break }
                }
            }
            offset += length
        }

        // Then Palatino at the exact size: scripts at TeX's 70 % (first level) / 50 % (deeper).
        // The style sample repeats the script direction so Paste Style keeps the shift.
        // keepColor: the inserted text already carries the stored colour of the text you typed.
        var styles: [(range: NSRange, style: CharacterStyle, keepColor: Bool)] = []
        var position = range.location
        for run in runs {
            let length = (run.text as NSString).length
            let font = run.italic ? italic : roman
            let scaled = NSFontManager.shared.convert(font, toSize: StyleSample.scriptSize(base: size, level: run.level))
            let direction = run.level > 0 ? 1 : (run.level < 0 ? -1 : 0)
            styles.append((NSRange(location: position, length: length),
                           CharacterStyle(font: scaled, color: color, baseline: direction), true))
            position += length
        }
        if !styler.pasteStyles(styles, ax: ax, el: el) { fail("Format ▸ Font ▸ Paste Style is unavailable in Notes.") }
        // Cursor after the zero-width space, which is on the baseline in the note's font.
        ax.setSelectedRange(of: el, NSRange(location: offset + 1, length: 0))

        store.add(.init(source: latex, display: false, text: plain, pixelHash: nil, date: Date()))
    }

    private func startRenderedMath(latex: String, over range: NSRange, text: NSString, ax: NotesAX, el: AXUIElement) {
        let latex = latex.replacingOccurrences(of: Formatter.zeroWidthSpace, with: "")   // see insertTextMath
        let source = text.substring(with: range)
        let size = ax.fontSize(of: el, at: max(0, range.location - 1))
        let dark = isDarkMode
        Task { await self.insertRenderedMath(latex: latex, source: source, near: range.location, fontSize: size, dark: dark) }
    }

    private func insertRenderedMath(latex: String, source: String, near location: Int,
                                    fontSize: CGFloat, dark: Bool) async {
        let equation: MathRenderer.Equation
        do {
            equation = try await renderer.render(latex, fontSize: fontSize, dark: dark)
        } catch {
            return fail("LaTeX: \(error.localizedDescription)")
        }
        // The user may have kept typing while we rendered: find the source text again.
        guard let ctx = currentContext(),
              let range = nearestOccurrence(of: source, in: ctx.text, near: location) else { return }
        let (ax, el, cursor) = (ctx.ax, ctx.element, ctx.selection)

        isBusy = true
        defer { isBusy = false }

        let image = NSImage(data: equation.png)
        image?.size = equation.size
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setData(equation.png, forType: .png)
        if let tiff = image?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        ax.setSelectedRange(of: el, range)
        pressPaste(ax)
        restore(pb, saved, after: 0.5)

        // Put the cursor back where the user was typing (shifted by the replaced length).
        if cursor.location >= NSMaxRange(range) {
            let shifted = cursor.location - range.length + 1   // the image is one U+FFFC character
            ax.setSelectedRange(of: el, NSRange(location: shifted, length: cursor.length))
        }
        store.add(.init(source: latex, display: true, text: nil,
                        pixelHash: MathRenderer.pixelHash(of: equation.png), date: Date()))
    }

    /// Replace a converted equation with its (unclosed) source so it can be edited; typing the
    /// closing delimiter or pressing ⌃⌘E converts it again.
    private func reopen(source: String, over range: NSRange, text: NSString, ax: NotesAX, el: AXUIElement) {
        // Remember what followed the equation on its line, so the reopened (unclosed) span ends
        // there rather than at the end of the line (see editingSpan).
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        var lineEnd = NSMaxRange(line)
        while lineEnd > NSMaxRange(range), let c = UnicodeScalar(text.character(at: lineEnd - 1)),
              CharacterSet.newlines.contains(c) { lineEnd -= 1 }
        let tail = lineEnd > NSMaxRange(range)
            ? text.substring(with: NSRange(location: NSMaxRange(range), length: lineEnd - NSMaxRange(range))) : ""
        editTail = (range.location, tail)

        // Delete the equation first, then insert at the empty spot: text inserted into a collapsed
        // selection takes the attributes of the character before it (the note's own font), not the
        // equation's Palatino Italic.
        guard ax.replace(in: el, range: range, with: ""),
              ax.replace(in: el, range: NSRange(location: range.location, length: 0), with: source)
        else { return fail("Couldn't edit the note text.") }
        let inserted = NSRange(location: range.location, length: (source as NSString).length)
        // The inserted text may still pick up superscript/subscript from its surroundings.
        ax.setSelectedRange(of: el, inserted)
        ax.pressMenuItem(path: Formatter.baselineResetPath)
        ax.setSelectedRange(of: el, NSRange(location: NSMaxRange(inserted), length: 0))
    }

    /// Copy the image attachment at `range` and recover its LaTeX: first from the PNG metadata,
    /// then by pixel hash in the equation history.
    private func sourceOfImage(at range: NSRange, ax: NotesAX, el: AXUIElement) -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        ax.setSelectedRange(of: el, range)
        let before = pb.changeCount
        if !ax.pressMenuItem("Copy") { ax.postKey(8, flags: .maskCommand) }   // ⌘C
        // The menu action is synchronous for Notes; give the pasteboard a moment regardless.
        let deadline = Date().addingTimeInterval(0.5)
        while pb.changeCount == before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        // Notes fills in the (large) rich-text copy lazily, so the attachment may not be there on the
        // first read. Retry quietly for up to 1.5 s; the last attempt logs what it saw.
        var source: String?
        let retryUntil = Date().addingTimeInterval(1.5)
        var attempt = 0
        while source == nil {
            attempt += 1
            let last = Date() >= retryUntil
            source = Formatter.equationSource(on: pb, store: store, log: last)
            if source != nil || last { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        Log.write("image source \(source == nil ? "not found" : "found") after \(attempt) read(s)")
        restore(pb, saved, after: 0)
        ax.setSelectedRange(of: el, NSRange(location: NSMaxRange(range), length: 0))
        return source
    }

    /// Recover an equation's LaTeX from whatever is on `pb` after copying an image in Notes.
    ///
    /// Notes doesn't put a plain image on the pasteboard; the original PNG comes back as the
    /// attachment inside `com.apple.flat-rtfd`. Every image-like payload is tried: the LaTeX in its
    /// PNG metadata first, then its pixel hash in the equation history. Each candidate is logged.
    static func equationSource(on pb: NSPasteboard, store: EquationStore, log: Bool = true) -> String? {
        func note(_ message: String) { if log { Log.write(message) } }
        var candidates: [(label: String, data: Data)] = []
        for item in pb.pasteboardItems ?? [] {
            note("copied attachment types: \(item.types.map(\.rawValue))")
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    note("  \(type.rawValue): no data"); continue
                }
                if type == .rtfd || type.rawValue == "com.apple.flat-rtfd" {
                    guard let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) else {
                        note("  \(type.rawValue): \(data.count) bytes, not parseable as RTFD"); continue
                    }
                    var found = 0
                    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                        guard let attachment = value as? NSTextAttachment else { return }
                        if let contents = attachment.fileWrapper?.regularFileContents ?? attachment.contents {
                            candidates.append(("\(type.rawValue) attachment", contents)); found += 1
                        }
                    }
                    note("  \(type.rawValue): \(data.count) bytes, \(found) attachment file(s)")
                } else {
                    candidates.append((type.rawValue, data))
                }
            }
        }
        for c in candidates {
            if let source = MathRenderer.embeddedSource(in: c.data) {
                note("  source found in \(c.label)")
                return source
            }
        }
        for c in candidates {
            if let hash = MathRenderer.pixelHash(of: c.data), let entry = store.source(forPixelHash: hash) {
                note("  source found by pixel hash of \(c.label)")
                return entry.source
            }
        }
        note("no equation source found among \(candidates.count) candidates: "
                  + candidates.map { "\($0.label) (\($0.data.count) B)" }.joined(separator: ", "))
        return nil
    }

    // MARK: - Pasteboard helpers

    /// Replace `range` with `text` linked to `url` (a `URL`, or a `String` Notes may still accept).
    ///
    /// Plain Paste (match style): the link attribute survives, the note's font is kept. With
    /// `trailingSpace`, a plain space follows the link so text typed next isn't part of it.
    /// Returns false (and records the error) if the paste didn't land.
    ///
    /// Example: `pasteLink(text: "paper.pdf", url: link, over: NSRange(location: 12, length: 0),
    /// trailingSpace: true, ax: ax, el: el)` inserts "paper.pdf " at offset 12.
    @discardableResult
    func pasteLink(text: String, url: Any, over range: NSRange, trailingSpace: Bool, ax: NotesAX, el: AXUIElement) -> Bool {
        let size = ax.fontSize(of: el, at: range.location)
        let snippet = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .link: url])
        if trailingSpace { snippet.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
        return paste(rtf: snippet, over: range, ax: ax, el: el) != nil
    }


    /// Paste `snippet` as RTF over `range`, wait (≤ 0.5 s) until the text appears in the note,
    /// and restore the clipboard afterwards.
    ///
    /// Returns the location where the snippet actually landed. Notes' Smart Copy/Paste may add a
    /// space next to pasted text, shifting it by a character or two, so a small window around the
    /// expected spot is searched. Returns nil if the paste couldn't be done or found.
    ///
    /// Used for links only: plain Paste maps the text onto the note's font and keeps the link.
    @discardableResult
    private func paste(rtf snippet: NSAttributedString, over range: NSRange, ax: NotesAX, el: AXUIElement) -> Int? {
        guard let rtf = try? snippet.data(from: NSRange(location: 0, length: snippet.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else { fail("Couldn't build rich text."); return nil }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setData(rtf, forType: .rtf)
        pb.setString(snippet.string, forType: .string)
        guard ax.setSelectedRange(of: el, range) else { fail("Couldn't select the Markdown text."); return nil }
        pressPaste(ax)
        restore(pb, saved, after: 0.5)

        let slack = 3
        let deadline = Date().addingTimeInterval(0.5)
        var lastLength = -1
        while Date() < deadline {
            if let text = ax.value(of: el) {
                lastLength = text.length
                let start = max(0, range.location - slack)
                let end = min(text.length, range.location + snippet.length + slack)
                if end > start {
                    let found = text.range(of: snippet.string, options: [], range: NSRange(location: start, length: end - start))
                    if found.location != NSNotFound {
                        if found.location != range.location {
                            Log.write("paste landed at offset \(found.location - range.location) from the expected spot")
                        }
                        return found.location
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        Log.write("paste not found: \(snippet.length) chars expected near \(range.location), note length \(lastLength)")
        fail("Paste into Notes didn't take effect.")
        return nil
    }

    private func pressPaste(_ ax: NotesAX) {
        if !ax.pressMenuItem("Paste") { ax.postKey(9, flags: .maskCommand) }   // ⌘V
    }

    private func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        }
    }

    /// Restore the user's clipboard, unless something else has written to it in the meantime.
    private func restore(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]], after delay: Double) {
        let ours = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    // MARK: - Misc

    private func isMonospaced(_ ax: NotesAX, _ el: AXUIElement, at location: Int) -> Bool {
        guard location >= 0, let name = ax.fontName(of: el, at: location)?.lowercased() else { return false }
        return name.contains("mono") || name.contains("menlo") || name.contains("courier")
    }

    private func nearestOccurrence(of needle: String, in text: NSString, near location: Int) -> NSRange? {
        var best: NSRange?
        var search = NSRange(location: 0, length: text.length)
        while true {
            let r = text.range(of: needle, options: [], range: search)
            if r.location == NSNotFound { break }
            if best == nil || abs(r.location - location) < abs(best!.location - location) { best = r }
            search = NSRange(location: r.location + 1, length: text.length - r.location - 1)
        }
        return best
    }

    private func fail(_ message: String) {
        lastError = message
        Log.write("error: \(message)")
        NSSound.beep()
    }
}
