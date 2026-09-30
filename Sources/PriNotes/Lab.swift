import AppKit
import ApplicationServices
import PriNotesCore

/// Experiment and regression harness: `open -n "Pri Notes.app" --args --notes-lab <report.txt> [--phaseN]`.
///
/// Drives the focused Notes note and writes what Notes did, read back through Accessibility, to a
/// report. For safety it only runs on a note whose text starts with "PRI-LAB". On any other note it
/// refuses and changes nothing. It rewrites that note's contents. Notes must stay frontmost while it runs,
/// because menu items are disabled otherwise.
///
/// - (default) phase 1: how Copy Style / Paste Style (the font pasteboard) behave.
/// - `--phase3`: every selection-toolbar change (family, typeface, size, colour, mixed runs).
/// - `--phase4`: `$…$` equations typed after styled text; equations keep Palatino under toolbar
///   changes and match the surrounding colour.
/// - `--phase7`: B/I/U/S toggles on and off, keeping font and colour.
/// Findings are recorded in docs/NOTES.md.
@MainActor
enum NotesLab {
    static let marker = "PRI-LAB"

    static func run(reportPath: String) -> Never {
        var report: [String] = []
        func out(_ s: String) { report.append(s); print(s) }
        func finish(_ code: Int32) -> Never {
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            exit(code)
        }

        guard AXIsProcessTrusted() else { out("not trusted for Accessibility"); finish(2) }
        guard let notes = NSRunningApplication.runningApplications(withBundleIdentifier: NotesAX.bundleID).first else {
            out("Notes is not running"); finish(2)
        }
        notes.activate()
        pause(0.8)
        let ax = NotesAX(pid: notes.processIdentifier)
        guard let el = ax.focusedTextArea(), let initial = ax.value(of: el) else {
            out("no focused note text area — click into the PRI-LAB note first"); finish(2)
        }
        guard initial.hasPrefix(marker) else {
            out("REFUSED: focused note does not start with \(marker); nothing was changed"); finish(3)
        }

        // Fresh test line after the marker line.
        let testLine = "alpha beta gamma delta epsilon"
        ax.replace(in: el, range: NSRange(location: 0, length: initial.length), with: marker + "\n" + testLine)
        pause(0.3)
        let base = (marker as NSString).length + 1
        func word(_ w: String) -> NSRange {
            let r = (testLine as NSString).range(of: w)
            return NSRange(location: base + r.location, length: r.length)
        }
        let fontPB = NSPasteboard(name: .font)

        func describe(_ range: NSRange) -> String {
            guard let a = attributed(ax, el, range) else { return "(no attributed string)" }
            var parts: [String] = []
            a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, r, _ in
                let text = (a.string as NSString).substring(with: r)
                let desc = attrs.map { key, value -> String in
                    if CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
                        let c = NSColor(cgColor: value as! CGColor)?.usingColorSpace(.sRGB)
                        return "\(key.rawValue)=rgb(\(c.map { String(format: "%.2f,%.2f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "?"))"
                    }
                    return "\(key.rawValue)=\(String(describing: value).replacingOccurrences(of: "\n", with: " "))"
                }.sorted().joined(separator: "; ")
                parts.append("'\(text)': \(desc)")
            }
            return parts.joined(separator: " | ")
        }
        func dumpFontPasteboard(_ title: String) {
            out("  font pasteboard (\(title)): types \(fontPB.types?.map(\.rawValue) ?? [])")
            for type in fontPB.types ?? [] {
                guard let data = fontPB.data(forType: type) else { continue }
                if let a = try? NSAttributedString(data: data, options: [:], documentAttributes: nil), a.length > 0 {
                    let attrs = a.attributes(at: 0, effectiveRange: nil)
                    out("    \(type.rawValue): \(data.count) B → " + attrs.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: "; "))
                } else {
                    out("    \(type.rawValue): \(data.count) B (not attributed text)")
                }
            }
        }
        /// Put a one-character style sample on the font pasteboard, then press Format ▸ Font ▸ Paste Style.
        func pasteStyle(_ attrs: [NSAttributedString.Key: Any], onto range: NSRange, type: NSPasteboard.PasteboardType) -> Bool {
            let sample = NSAttributedString(string: "x", attributes: attrs)
            guard let rtf = try? sample.data(from: NSRange(location: 0, length: 1),
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return false }
            fontPB.clearContents()
            fontPB.setData(rtf, forType: type)
            ax.setSelectedRange(of: el, range)
            let pressed = ax.pressMenuItem("Paste Style")
            pause(0.3)
            return pressed
        }

        if CommandLine.arguments.contains("--phase7") {
            // The toolbar's reliable toggles, end to end.
            let styler = SelectionStyler(formatter: Formatter())
            let lineRange = NSRange(location: word("alpha").location, length: NSMaxRange(word("epsilon")) - word("alpha").location)
            ax.setSelectedRange(of: el, lineRange); ax.pressMenuItem("Body"); pause(0.3)
            ax.setSelectedRange(of: el, lineRange); ax.pressMenuItem("Remove Style"); pause(0.4)
            func state(_ w: String) -> String {
                let runs = styler.runs(in: word(w), ax: ax, el: el)
                return runs.map { r in
                    let c = r.style.color.map { c -> String in let s = c.usingColorSpace(.sRGB)!
                        return String(format: "rgb(%.2f,%.2f,%.2f)", s.redComponent, s.greenComponent, s.blueComponent) } ?? "automatic"
                    return "\(r.style.font.fontName) \(r.style.font.pointSize) U\(r.underline ? 1 : 0) S\(r.strikethrough ? 1 : 0) \(c)"
                }.joined(separator: " | ") + "  [text: \((ax.value(of: el) ?? "" as NSString).substring(with: word(w)))]"
            }
            func toggle(_ t: SelectionStyler.InlineStyleToggle, _ w: String) { styler.apply(.toggle(t), to: word(w)); pause(0.3) }

            out("== U1 alpha: underline on, off")
            toggle(.underline, "alpha"); out("  on  → \(state("alpha"))")
            toggle(.underline, "alpha"); out("  off → \(state("alpha"))")
            out("== B1 beta: bold on, off")
            toggle(.bold, "beta"); out("  on  → \(state("beta"))")
            toggle(.bold, "beta"); out("  off → \(state("beta"))")
            out("== I1 gamma: Georgia + red, italic on, off")
            styler.apply(.family("Georgia"), to: word("gamma")); pause(0.2)
            styler.apply(.color(.systemRed), to: word("gamma")); pause(0.2)
            out("  start → \(state("gamma"))")
            toggle(.italic, "gamma"); out("  on    → \(state("gamma"))")
            toggle(.italic, "gamma"); out("  off   → \(state("gamma"))")
            out("== U2 delta: red + strikethrough + underline, then underline off (strike and colour must stay)")
            styler.apply(.color(.systemRed), to: word("delta")); pause(0.2)
            toggle(.strikethrough, "delta"); toggle(.underline, "delta")
            out("  start → \(state("delta"))")
            toggle(.underline, "delta"); out("  off   → \(state("delta"))")
            out("== S1 epsilon: strikethrough on, off")
            toggle(.strikethrough, "epsilon"); out("  on  → \(state("epsilon"))")
            toggle(.strikethrough, "epsilon"); out("  off → \(state("epsilon"))")
            out("text intact: \((ax.value(of: el) ?? "").hasSuffix(testLine))")
            finish(0)
        }

        if CommandLine.arguments.contains("--phase4") {
            // Reproduce "equation paste didn't take effect" after toolbar colour/style edits: type a $…$
            // equation after differently styled text and run the real Markdown/equation code.
            let formatter = Formatter()
            let styler = SelectionStyler(formatter: formatter)
            func typeEquation(after context: String, style: SelectionStyler.Change?, label: String) {
                guard let text = ax.value(of: el) else { return }
                let start = text.length
                ax.replace(in: el, range: NSRange(location: start, length: 0), with: "\n" + context)
                pause(0.2)
                let contextRange = NSRange(location: start + 1, length: (context as NSString).length)
                if let style { styler.apply(style, to: contextRange); pause(0.2) }
                // "Type" the equation at the end: inserted text takes the preceding character's style.
                let end = (ax.value(of: el) ?? "").length
                ax.replace(in: el, range: NSRange(location: end, length: 0), with: " $x_b^2$")
                ax.setSelectedRange(of: el, NSRange(location: end + 8, length: 0))
                pause(0.1)
                let logBefore = (try? String(contentsOf: Log.url, encoding: .utf8))?.count ?? 0
                formatter.check()
                pause(0.8)
                let after = ax.value(of: el) ?? ""
                let line = after.substring(from: start + 1)
                let newLog = ((try? String(contentsOf: Log.url, encoding: .utf8)) ?? "").dropFirst(logBefore)
                out("== \(label)")
                out("  line now: \(line.debugDescription)")
                let eqStart = start + 1 + (context as NSString).length + 1
                if eqStart < after.length {
                    let runs = styler.runs(in: NSRange(location: eqStart, length: after.length - eqStart), ax: ax, el: el)
                    for r in runs {
                        let c = r.style.color.map { c -> String in let s = c.usingColorSpace(.sRGB)!
                            return String(format: "rgb(%.2f,%.2f,%.2f)", s.redComponent, s.greenComponent, s.blueComponent) } ?? "automatic"
                        out("  run \((after as NSString).substring(with: r.range).debugDescription): \(r.style.font.fontName) \(r.style.font.pointSize) baseline \(r.style.baseline) colour \(c)")
                    }
                }
                if !newLog.isEmpty { out("  log: " + newLog.replacingOccurrences(of: "\n", with: " | ")) }
            }
            typeEquation(after: "plain text", style: nil, label: "A. after plain text")
            typeEquation(after: "red text", style: .color(.systemRed), label: "B. after red text")
            typeEquation(after: "georgia text", style: .family("Georgia"), label: "C. after Georgia text")
            typeEquation(after: "bold text", style: .toggle(.bold), label: "D. after bold text")
            typeEquation(after: "big text", style: .size(20), label: "E. after 20 pt text")

            // F/G: toolbar changes over a sentence containing an equation.
            typeEquation(after: "sentence with", style: nil, label: "F0. sentence with an equation")
            let full = ax.value(of: el) ?? ""
            let lineRange = full.paragraphRange(for: NSRange(location: full.length - 1, length: 0))
            ax.replace(in: el, range: NSRange(location: full.length, length: 0), with: " and more")
            pause(0.2)
            let sentence = NSRange(location: lineRange.location, length: (ax.value(of: el) ?? "").length - lineRange.location)
            func report(_ label: String) {
                out("== \(label)")
                let text = (ax.value(of: el) ?? "") as NSString
                for r in styler.runs(in: sentence, ax: ax, el: el) {
                    let c = r.style.color.map { c -> String in let s = c.usingColorSpace(.sRGB)!
                        return String(format: "rgb(%.2f,%.2f,%.2f)", s.redComponent, s.greenComponent, s.blueComponent) } ?? "automatic"
                    out("  \(text.substring(with: r.range).debugDescription): \(r.style.font.fontName) \(r.style.font.pointSize) baseline \(r.style.baseline) \(c)")
                }
            }
            styler.apply(.family("Georgia"), to: sentence); pause(0.2)
            styler.apply(.toggle(.bold), to: sentence); pause(0.2)
            report("F. sentence → Georgia, then Bold (equation must stay Palatino)")
            styler.apply(.color(.systemBlue), to: sentence); pause(0.2)
            report("G. sentence → blue (equation must turn blue, still Palatino)")
            finish(0)
        }

        if CommandLine.arguments.contains("--phase3") {
            // End-to-end test of the selection toolbar's styler (no UI): every change, read back via AX.
            let styler = SelectionStyler(formatter: Formatter())
            let line = NSRange(location: word("alpha").location, length: NSMaxRange(word("epsilon")) - word("alpha").location)
            ax.setSelectedRange(of: el, line); ax.pressMenuItem("Body"); pause(0.3)
            func show(_ label: String, _ w: String) {
                let runs = styler.runs(in: word(w), ax: ax, el: el)
                let s = styler.summary(of: runs)
                let color = s?.color.map { $0.map { c -> String in
                    let c = c.usingColorSpace(.sRGB)!
                    return String(format: "rgb(%.2f,%.2f,%.2f)", c.redComponent, c.greenComponent, c.blueComponent) } ?? "automatic" } ?? "mixed"
                out("\(label) → \(w): family \(s?.family ?? "mixed"), face \(s?.face ?? "mixed"), size \(s?.size.map { "\($0)" } ?? "mixed"), "
                    + "B\(s?.bold == true ? 1 : 0) I\(s?.italic == true ? 1 : 0) U\(s?.underline == true ? 1 : 0) S\(s?.strikethrough == true ? 1 : 0), colour \(color)")
            }
            show("baseline", "alpha")
            styler.apply(.family("Palatino"), to: word("alpha")); pause(0.2); show("family Palatino", "alpha")
            styler.apply(.toggle(.bold), to: word("alpha")); pause(0.2); show("toggle bold", "alpha")
            styler.apply(.family(StyleSample.systemFamilyLabel), to: word("alpha")); pause(0.2); show("family System (keeps bold)", "alpha")
            styler.apply(.size(24), to: word("beta")); pause(0.2); show("size 24", "beta")
            styler.apply(.step(1), to: word("beta")); pause(0.2); show("step +1", "beta")
            styler.apply(.color(.systemRed), to: word("gamma")); pause(0.2); show("colour red", "gamma")
            styler.apply(.color(nil), to: word("gamma")); pause(0.2); show("colour automatic", "gamma")
            styler.apply(.systemFace(weight: .bold, italic: true), to: word("delta")); pause(0.2); show("system Bold Italic", "delta")
            styler.apply(.toggle(.underline), to: word("epsilon")); pause(0.2)
            styler.apply(.face(postScriptName: "Georgia-Italic"), to: word("epsilon")); pause(0.2); show("underline then Georgia Italic", "epsilon")
            // Mixed selection: two differently styled words, change family, each keeps its own traits.
            let pair = NSRange(location: word("alpha").location, length: NSMaxRange(word("beta")) - word("alpha").location)
            styler.apply(.family("Avenir Next"), to: pair); pause(0.2)
            show("mixed → Avenir Next", "alpha"); show("mixed → Avenir Next", "beta")
            out("text intact: \((ax.value(of: el) ?? "").hasSuffix(testLine))")
            finish(0)
        }

        out("== 0. baseline attributes of the test line")
        out("  " + describe(NSRange(location: base, length: (testLine as NSString).length)))

        out("== 1. Copy Style on 'alpha' (what Notes writes to the font pasteboard)")
        ax.setSelectedRange(of: el, word("alpha"))
        out("  pressed Copy Style: \(ax.pressMenuItem("Copy Style"))")
        pause(0.3)
        dumpFontPasteboard("after Copy Style")
        let notesStyleType = fontPB.types?.first ?? .font
        out("  using pasteboard type for writes: \(notesStyleType.rawValue)")

        out("== 2. Paste Style: family Palatino 13 onto 'beta'")
        let pal = NSFont(name: "Palatino-Roman", size: 13)!
        out("  pressed: \(pasteStyle([.font: pal], onto: word("beta"), type: notesStyleType))")
        out("  beta → " + describe(word("beta")))

        out("== 3. Paste Style: system 22 pt onto 'gamma'")
        out("  pressed: \(pasteStyle([.font: NSFont.systemFont(ofSize: 22)], onto: word("gamma"), type: notesStyleType))")
        out("  gamma → " + describe(word("gamma")))

        out("== 4. Paste Style: system 13 + red colour onto 'delta'")
        out("  pressed: \(pasteStyle([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed], onto: word("delta"), type: notesStyleType))")
        out("  delta → " + describe(word("delta")))

        out("== 5. Preservation: make 'epsilon' bold + underlined via menu, then Paste Style Palatino (no underline given)")
        ax.setSelectedRange(of: el, word("epsilon"))
        ax.pressMenuItem("Bold"); pause(0.2)
        ax.pressMenuItem("Underline"); pause(0.2)
        out("  before → " + describe(word("epsilon")))
        out("  pressed: \(pasteStyle([.font: pal], onto: word("epsilon"), type: notesStyleType))")
        out("  after  → " + describe(word("epsilon")))

        out("== 6. Automatic colour: Paste Style with no colour onto red 'delta'")
        out("  pressed: \(pasteStyle([.font: NSFont.systemFont(ofSize: 13)], onto: word("delta"), type: notesStyleType))")
        out("  delta → " + describe(word("delta")))

        out("== 7. Copy Style on the red/Palatino words, to see how Notes encodes them")
        _ = pasteStyle([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemBlue], onto: word("delta"), type: notesStyleType)
        ax.setSelectedRange(of: el, word("delta"))
        ax.pressMenuItem("Copy Style"); pause(0.3)
        dumpFontPasteboard("Copy Style on blue delta")

        out("== 8. Undo check: text unchanged?")
        let final = ax.value(of: el) ?? ""
        out("  line text intact: \(final.hasSuffix(testLine))")
        ax.setSelectedRange(of: el, NSRange(location: final.length, length: 0))
        finish(0)
    }

    /// Second round: keep the system font through Paste Style (hand-written RTF naming
    private static func attributed(_ ax: NotesAX, _ el: AXUIElement, _ range: NSRange) -> NSAttributedString? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXAttributedStringForRangeParameterizedAttribute as CFString, v, &result) == .success else { return nil }
        return result as? NSAttributedString
    }

    private static func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
