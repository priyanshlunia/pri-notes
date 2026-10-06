import AppKit
import PriNotesCore

/// Reads and changes the character style of the current selection in Notes.
///
/// How changes are applied (all verified with `--notes-lab`):
/// - Bold / Italic / Underline / Strikethrough and size ± 1 pt press Notes' own Format ▸ Font items
///   on the whole selection, so everything else about the text is untouched.
/// - Family, typeface, exact size and colour are applied **per style run**: for each run the new
///   style is written as a one-character RTF sample (`StyleSample.rtf`) to the *font* pasteboard,
///   the run is selected, and Format ▸ Font ▸ Paste Style is pressed. Paste Style changes font and
///   colour but keeps underline/strikethrough and never touches the text, links or attachments.
///   Doing it per run keeps each run's own traits (e.g. a bold word stays bold in the new family).
///   The user's font pasteboard is restored afterwards; the general clipboard is never used.
///
/// Notes only enables its menu items while it is the frontmost app, so every change first makes
/// sure Notes is in front.
@MainActor
final class SelectionStyler {
    /// One run of uniformly styled text in the selection.
    struct Run {
        let range: NSRange
        var style: CharacterStyle
        let underline: Bool
        let strikethrough: Bool
        /// Part of a link: never retyped (that would drop the link).
        let hasLink: Bool
    }

    /// What the toolbar shows for the current selection. nil fields mean "mixed".
    struct Summary: Equatable {
        var family: String?
        var face: String?
        var size: CGFloat?
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strikethrough: Bool
        /// .some(nil) = automatic colour; nil = mixed.
        var color: NSColor??
    }

    enum Change {
        case family(String)
        /// A face within the current family: a PostScript name, or a system weight + italic.
        case face(postScriptName: String)
        case systemFace(weight: NSFont.Weight, italic: Bool)
        case size(CGFloat)
        case step(Int)                      // +1 Bigger, −1 Smaller
        case color(NSColor?)                // nil = automatic
        case toggle(InlineStyleToggle)
    }

    enum InlineStyleToggle: String { case bold = "Bold", italic = "Italic", underline = "Underline", strikethrough = "Strikethrough" }

    private let formatter: Formatter

    init(formatter: Formatter) {
        self.formatter = formatter
    }

    // MARK: - Reading

    /// Style runs of `range` in the focused note, skipping attachments (images, equation PNGs).
    func runs(in range: NSRange, ax: NotesAX, el: AXUIElement) -> [Run] {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return [] }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXAttributedStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
              let attributed = result as? NSAttributedString else { return [] }

        let text = attributed.string as NSString
        var runs: [Run] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, r, _ in
            if text.substring(with: r).allSatisfy({ $0 == "\u{FFFC}" }) { return }   // attachment
            let font = Self.font(from: attrs[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)])
            let color = Self.explicitColor(from: attrs[NSAttributedString.Key(kAXForegroundColorTextAttribute.takeUnretainedValue() as String)])
            let superscript = (attrs[NSAttributedString.Key(kAXSuperscriptTextAttribute.takeUnretainedValue() as String)] as? NSNumber)?.intValue ?? 0
            let underline = ((attrs[NSAttributedString.Key(kAXUnderlineTextAttribute.takeUnretainedValue() as String)] as? NSNumber)?.intValue ?? 0) != 0
            let strike = ((attrs[NSAttributedString.Key(kAXStrikethroughTextAttribute.takeUnretainedValue() as String)] as? NSNumber)?.intValue ?? 0) != 0
            let link = attrs[NSAttributedString.Key(kAXLinkTextAttribute.takeUnretainedValue() as String)] != nil
            runs.append(Run(range: NSRange(location: range.location + r.location, length: r.length),
                            style: CharacterStyle(font: font, color: color, baseline: superscript),
                            underline: underline, strikethrough: strike, hasLink: link))
        }
        return runs
    }

    func summary(of runs: [Run]) -> Summary? {
        guard let first = runs.first else { return nil }
        let fm = NSFontManager.shared
        func uniform<T: Equatable>(_ f: (Run) -> T) -> T? {
            let v = f(first); return runs.allSatisfy { f($0) == v } ? v : nil
        }
        let colors = runs.map { $0.style.color?.usingColorSpace(.sRGB) }
        let sameColor = colors.allSatisfy { c in
            switch (c, colors[0]) {
            case (nil, nil): return true
            case let (a?, b?): return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent) < 0.03
            default: return false
            }
        }
        return Summary(
            family: uniform { StyleSample.familyLabel(of: $0.style.font) },
            face: uniform { Self.faceName(of: $0.style.font) },
            size: uniform { $0.style.font.pointSize },
            bold: fm.traits(of: first.style.font).contains(.boldFontMask),
            italic: fm.traits(of: first.style.font).contains(.italicFontMask),
            underline: first.underline,
            strikethrough: first.strikethrough,
            color: sameColor ? .some(first.style.color) : nil)
    }

    /// Face name as shown in the typeface menu ("Bold Italic", "Semibold", …).
    static func faceName(of font: NSFont) -> String {
        let fm = NSFontManager.shared
        if StyleSample.isSystem(font) {
            let weight = StyleSample.systemWeight(of: font)
            let name = StyleSample.systemWeights.first { $0.weight == weight }?.name ?? "Regular"
            let italic = fm.traits(of: font).contains(.italicFontMask)
            return italic ? (name == "Regular" ? "Italic" : "\(name) Italic") : name
        }
        let members = fm.availableMembers(ofFontFamily: font.familyName ?? "") ?? []
        return members.first { ($0[0] as? String) == font.fontName }?[1] as? String ?? font.fontName
    }

    // MARK: - Applying

    /// Apply `change` to `selection` in the focused note, then reselect it.
    ///
    /// Text equations (see `equationRanges`) always stay in Palatino: font family, typeface and
    /// Bold/Italic changes skip them, while colour, size, underline and strikethrough apply to them too.
    func apply(_ change: Change, to selection: NSRange) {
        guard ensureNotesFrontmost(), let ctx = formatter.currentContext() else {
            Log.write("toolbar: Notes not frontmost/focused; change skipped"); NSSound.beep(); return
        }
        let (ax, el) = (ctx.ax, ctx.element)
        let equations = equationRanges(around: selection, text: ctx.text, ax: ax, el: el)
        func inEquation(_ r: NSRange) -> Bool { equations.contains { NSIntersectionRange($0, r).length == r.length } }

        switch change {
        case let .toggle(style):
            // Notes' own Bold/Italic/Underline menu items only ever *add* the style when driven
            // this way (and Underline even from the keyboard): measured with `--notes-lab --phase6`.
            // So the state is decided here, Pages-style: if every run already has it, remove it,
            // otherwise add it everywhere, and each run is changed explicitly.
            let fm = NSFontManager.shared
            let allRuns = runs(in: selection, ax: ax, el: el)
            // Equations keep their Palatino italic/roman faces.
            let targets = (style == .bold || style == .italic) ? allRuns.filter { !inEquation($0.range) } : allRuns
            func has(_ run: Run) -> Bool {
                switch style {
                case .bold: return fm.traits(of: run.style.font).contains(.boldFontMask)
                case .italic: return fm.traits(of: run.style.font).contains(.italicFontMask)
                case .underline: return run.underline
                case .strikethrough: return run.strikethrough
                }
            }
            let turnOn = !targets.allSatisfy(has)
            let changing = targets.filter { has($0) != turnOn }
            switch style {
            case .bold, .italic:
                // Set the font directly: same family, size and colour, with the trait added/removed.
                let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
                pasteStyles(changing.map { run in
                    var s = run.style
                    s.font = Self.font(run.style.font, trait: trait, on: turnOn)
                    return (run.range, s, true)
                }, ax: ax, el: el)
            case .strikethrough:
                // Notes' Strikethrough toggles correctly both ways.
                for run in changing { ax.setSelectedRange(of: el, run.range); ax.pressMenuItem(style.rawValue) }
            case .underline:
                if turnOn {
                    for run in changing { ax.setSelectedRange(of: el, run.range); ax.pressMenuItem(style.rawValue) }
                } else {
                    removeUnderline(from: changing, ax: ax, el: el)
                }
            }
        case let .step(direction):
            ax.setSelectedRange(of: el, selection)
            ax.pressMenuItem(direction > 0 ? "Bigger" : "Smaller")
        default:
            let keepsFont: Bool
            switch change { case .family, .face, .systemFace: keepsFont = false; default: keepsFont = true }
            let items = runs(in: selection, ax: ax, el: el)
                .filter { keepsFont || !inEquation($0.range) }
                .map { run -> (range: NSRange, style: CharacterStyle, keepColor: Bool) in
                    var keep = true
                    if case .color = change { keep = false }   // a new colour replaces the old one
                    return (run.range, restyled(run.style, by: change), keep)
                }
            pasteStyles(items, ax: ax, el: el)
        }
        ax.setSelectedRange(of: el, selection)
    }

    /// Apply each style to its range with Format ▸ Font ▸ Paste Style, via the font pasteboard
    /// (never the general clipboard), waiting for each to land. The user's font pasteboard is restored.
    /// Returns false if Paste Style was unavailable.
    ///
    /// `keepColor`: the range should keep the colour it already has. Accessibility reports colours as
    /// *drawn*, and in dark mode Notes draws explicit colours lighter than it stores them, so writing
    /// the drawn colour back makes it drift paler on every edit (measured: 0.36 → 0.45 → 0.54 → 0.62).
    /// The stored colour is read instead with Notes' own Format ▸ Font ▸ Copy Style (`storedColor`).
    /// Automatic colour needs no lookup.
    @discardableResult
    func pasteStyles(_ items: [(range: NSRange, style: CharacterStyle, keepColor: Bool)], ax: NotesAX, el: AXUIElement) -> Bool {
        let fontPB = NSPasteboard(name: .font)
        let saved = (fontPB.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        }
        var ok = true
        for item in items where item.range.length > 0 {
            var style = item.style
            if item.keepColor, style.color != nil {
                style.color = storedColor(at: item.range, fontPB: fontPB, ax: ax, el: el) ?? style.color
            }
            let rtf = StyleSample.rtf(style)
            fontPB.clearContents()
            fontPB.setData(rtf, forType: NSPasteboard.PasteboardType("com.apple.cocoa.pasteboard.character-formatting"))
            fontPB.setData(rtf, forType: NSPasteboard.PasteboardType("NeXT font pasteboard type"))
            ax.setSelectedRange(of: el, item.range)
            if !ax.pressMenuItem("Paste Style") {
                Log.write("Paste Style unavailable"); ok = false; break
            }
            // Notes reads the font pasteboard after the menu press returns, so the pasteboard
            // must not change until the new style has actually landed on this range.
            if !waitForStyle(style, on: item.range, ax: ax, el: el) {
                Log.write("style not confirmed on \(item.range) within 0.6 s")
            }
        }
        fontPB.clearContents()
        if !saved.isEmpty {
            fontPB.writeObjects(saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            })
        }
        return ok
    }

    /// `font` with bold or italic switched on/off, keeping family and size. System fonts are rebuilt
    /// from their weight and italic flags so they stay the system font.
    static func font(_ font: NSFont, trait: NSFontTraitMask, on: Bool) -> NSFont {
        let fm = NSFontManager.shared
        if StyleSample.isSystem(font) {
            let traits = fm.traits(of: font)
            let bold = trait == .boldFontMask ? on : traits.contains(.boldFontMask)
            let italic = trait == .italicFontMask ? on : traits.contains(.italicFontMask)
            return StyleSample.systemFace(weight: bold ? .bold : .regular, italic: italic, size: font.pointSize)
        }
        return on ? fm.convert(font, toHaveTrait: trait) : fm.convert(font, toNotHaveTrait: trait)
    }

    /// Remove underline by retyping each run in place, since Notes can't switch underline off.
    ///
    /// Deleting a run and inserting the same text at the same spot gives it the style of the
    /// character before it (not underlined, in the usual case). The run's own font, stored colour,
    /// size and script direction are then restored with Paste Style, and strikethrough re-added.
    /// Runs inside links are skipped: retyping would drop the link. If the preceding character is
    /// itself underlined, the retyped text inherits that and stays underlined (logged).
    private func removeUnderline(from runs: [Run], ax: NotesAX, el: AXUIElement) {
        let fontPB = NSPasteboard(name: .font)
        let saved = (fontPB.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        }
        for run in runs {
            if run.hasLink { Log.write("underline kept on link text at \(run.range)"); continue }
            guard let text = ax.value(of: el), NSMaxRange(run.range) <= text.length else { continue }
            let content = text.substring(with: run.range)
            // Read the stored colour before the text (and its colour) is gone.
            var style = run.style
            if style.color != nil { style.color = storedColor(at: run.range, fontPB: fontPB, ax: ax, el: el) ?? style.color }
            style.baseline = run.style.baseline > 0 ? 1 : (run.style.baseline < 0 ? -1 : 0)

            guard ax.replace(in: el, range: run.range, with: ""),
                  ax.replace(in: el, range: NSRange(location: run.range.location, length: 0), with: content) else {
                Log.write("underline removal: couldn't retype \(run.range)"); continue
            }
            pasteStyles([(run.range, style, false)], ax: ax, el: el)
            if run.strikethrough { ax.setSelectedRange(of: el, run.range); ax.pressMenuItem("Strikethrough") }
            if self.runs(in: run.range, ax: ax, el: el).contains(where: \.underline) {
                Log.write("underline removal: \(run.range) inherited an underline from the preceding character")
            }
        }
        fontPB.clearContents()
        if !saved.isEmpty {
            fontPB.writeObjects(saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            })
        }
    }

    /// The colour Notes has stored for the first character of `range`, read via Copy Style.
    private func storedColor(at range: NSRange, fontPB: NSPasteboard, ax: NotesAX, el: AXUIElement) -> NSColor? {
        ax.setSelectedRange(of: el, NSRange(location: range.location, length: 1))
        let before = fontPB.changeCount
        guard ax.pressMenuItem("Copy Style") else { return nil }
        guard fontPB.waitForChange(since: before, timeout: 0.5),
              let data = fontPB.data(forType: NSPasteboard.PasteboardType("com.apple.cocoa.pasteboard.character-formatting")),
              let copied = try? NSAttributedString(data: data, options: [:], documentAttributes: nil), copied.length > 0
        else { Log.write("Copy Style gave no colour for \(range)"); return nil }
        return copied.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    /// Text equations touching `selection`: a stretch of Palatino text immediately followed by the
    /// zero-width space that every inserted `$…$` equation ends with. The stretch may extend past
    /// the selection, so the rest of the paragraph is inspected too.
    func equationRanges(around selection: NSRange, text: NSString, ax: NotesAX, el: AXUIElement) -> [NSRange] {
        let paragraph = text.paragraphRange(for: selection)
        let window = NSRange(location: paragraph.location, length: NSMaxRange(paragraph) - paragraph.location)
        var result: [NSRange] = []
        var stretch: NSRange?
        for run in runs(in: window, ax: ax, el: el) {
            if run.style.font.familyName == "Palatino" {
                stretch = stretch.map { NSUnionRange($0, run.range) } ?? run.range
                continue
            }
            if let s = stretch, NSMaxRange(s) < text.length,
               text.substring(with: NSRange(location: NSMaxRange(s), length: 1)) == Formatter.zeroWidthSpace,
               NSIntersectionRange(s, selection).length > 0 {
                result.append(s)
            }
            stretch = nil
        }
        return result
    }


    /// Poll the run until its family, face, size and colour (automatic or not) match `style`.
    private func waitForStyle(_ style: CharacterStyle, on range: NSRange, ax: NotesAX, el: AXUIElement) -> Bool {
        let expectedFont = StyleSample.normalized(style.font)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if let now = runs(in: range, ax: ax, el: el).first?.style {
                let sameFont = StyleSample.familyLabel(of: now.font) == StyleSample.familyLabel(of: expectedFont)
                    && Self.faceName(of: now.font) == Self.faceName(of: expectedFont)
                    && abs(now.font.pointSize - expectedFont.pointSize) < 0.5
                let sameColor = (now.color == nil) == (style.color == nil)
                if sameFont && sameColor { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    private func restyled(_ style: CharacterStyle, by change: Change) -> CharacterStyle {
        var s = style
        let size = style.font.pointSize
        switch change {
        case let .family(family):
            s.font = StyleSample.convert(style.font, toFamily: family)
        case let .face(postScriptName):
            s.font = NSFont(name: postScriptName, size: size) ?? style.font
        case let .systemFace(weight, italic):
            s.font = StyleSample.systemFace(weight: weight, italic: italic, size: size)
        case let .size(newSize):
            // Superscripts/subscripts keep their smaller size relative to the new size (equations).
            let target = StyleSample.scriptSize(base: newSize, level: style.baseline)
            s.font = NSFontManager.shared.convert(StyleSample.normalized(style.font), toSize: target)
        case let .color(color):
            s.color = color
        case .step, .toggle:
            break
        }
        return s
    }

    /// Bring Notes to the front if needed (e.g. after using the colour panel) and wait for it.
    func ensureNotesFrontmost() -> Bool {
        if NotesAX.isFrontmost { return true }
        guard let notes = NotesAX.runningApp else { return false }
        notes.activate()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if NotesAX.isFrontmost { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return false
    }

    // MARK: - AX attribute conversion

    /// NSFont from AX's font dictionary (AXFontName, AXFontSize); system fonts are normalized.
    private static func font(from value: Any?) -> NSFont {
        let dict = value as? [String: Any]
        let size = (dict?[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 13
        let name = dict?[kAXFontNameKey.takeUnretainedValue() as String] as? String ?? ""
        let font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        return StyleSample.normalized(font)
    }

    /// The run's colour, or nil if it is Notes' automatic text colour. AX reports the *resolved*
    /// colour, so "automatic" is recognised as a neutral grey at the extreme for the appearance
    /// (near-white in dark mode, near-black in light mode); the palette's grey stays explicit.
    private static func explicitColor(from value: Any?) -> NSColor? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
              let color = NSColor(cgColor: value as! CGColor)?.usingColorSpace(.sRGB) else { return nil }
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        let neutral = max(r, g, b) - min(r, g, b) < 0.04
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if neutral && (dark ? r > 0.8 : r < 0.25) { return nil }
        return color
    }
}
