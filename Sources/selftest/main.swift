// Assertion-based tests for PriNotesCore. Run with `swift run selftest`.
import AppKit
import PriNotesCore

var failures = 0
var passes = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if ok { passes += 1 } else { failures += 1; print("FAIL: \(message())") }
}

/// Detect on `text` with the cursor at the end.
func detect(_ text: String, _ enabled: RuleSet = .all) -> Action? {
    let s = text as NSString
    return Rules.detect(in: s, cursor: s.length, enabled: enabled)
}

func r(_ loc: Int, _ len: Int) -> NSRange { NSRange(location: loc, length: len) }

// MARK: - Block rules
check(detect("# ") == .block(.title, prefixRange: r(0, 2)), "# → title")
check(detect("Intro\n## ") == .block(.heading, prefixRange: r(6, 3)), "## → heading on 2nd line")
check(detect("### ") == .block(.subheading, prefixRange: r(0, 4)), "### → subheading")
check(detect("```") == .block(.monostyled, prefixRange: r(0, 3)), "``` → monostyled")
check(detect("[] ") == .block(.checklist, prefixRange: r(0, 3)), "[] → checklist")
check(detect("[ ] ") == .block(.checklist, prefixRange: r(0, 4)), "[ ] → checklist")
check(detect("> ") == .block(.blockQuote, prefixRange: r(0, 2)), "> → quote")
check(detect("text # ") == nil, "# mid-line is ignored")
check(detect("#### ") == nil, "#### ignored")
check(detect("## ", [.inline]) == nil, "blocks disabled")

// MARK: - Inline rules
check(detect("a **bold**") == .inline(.bold, matchRange: r(2, 8), inner: "bold"), "bold")
check(detect("**bold*") == nil, "half-closed bold is not italic")
check(detect("an *it*") == .inline(.italic, matchRange: r(3, 4), inner: "it"), "italic *")
check(detect("an _it_") == .inline(.italic, matchRange: r(3, 4), inner: "it"), "italic _")
check(detect("my_var_") == nil, "snake_case untouched")
check(detect("2*3*") == nil, "arithmetic untouched")
check(detect("__under__") == .inline(.underline, matchRange: r(0, 9), inner: "under"), "underline")
check(detect("__under_") == nil, "half-closed underline is not italic")
check(detect("~~gone~~") == .inline(.strikethrough, matchRange: r(0, 8), inner: "gone"), "strike")
check(detect("** x**") == nil, "space after opener")
check(detect("**two words**") == .inline(.bold, matchRange: r(0, 13), inner: "two words"), "bold with space")
check(detect("see `x = 1` ") == .code(matchRange: r(4, 8), inner: "x = 1"), "inline code on space")
check(detect("see `x`") == nil, "code waits for the space")
check(detect("**b**", [.blocks]) == nil, "inline disabled")

// MARK: - Links
check(detect("go [Apple](https://apple.com) ") ==
      .link(matchRange: r(3, 27), text: "Apple", url: "https://apple.com"), "link")
check(detect("![img](a.png) ") == nil, "image syntax ignored")

// MARK: - Math
check(detect("so $x^2$") == .unicodeMath(matchRange: r(3, 5), latex: "x^2"), "inline $")
check(detect("costs $5 and $") == nil, "prices: closing $ after space")
check(detect("$$x$") == nil, "half-closed $$ is not $")
check(detect("$$E=mc^2$$") == .renderedMath(matchRange: r(0, 10), latex: "E=mc^2"), "display $$")
check(detect("$$ a $$") == .renderedMath(matchRange: r(0, 7), latex: "a"), "display with spaces")
check(detect("$$  $$") == nil, "empty display")
check(detect("\\$x$") == nil, "escaped $")

check(detect("$(a)_1 + (b)_") == nil, "underscores inside open math are not italic")
check(detect("$a*b*") == nil, "stars inside open math are not italic")
check(detect("$x$ and *it*") == .inline(.italic, matchRange: r(8, 4), inner: "it"), "italic after closed math")

// MARK: - Smart symbols
check(detect("a -> ") == .symbol(matchRange: r(2, 2), replacement: "→"), "-> on space")
check(detect("-> ") == .symbol(matchRange: r(0, 2), replacement: "→"), "at line start")
check(detect("a <-> ") == .symbol(matchRange: r(2, 3), replacement: "↔"), "<-> beats <-")
check(detect("p <=> ") == .symbol(matchRange: r(2, 3), replacement: "⇔"), "<=> beats <= and =>")
check(detect("x <= ") == .symbol(matchRange: r(2, 2), replacement: "≤"), "<=")
check(detect("x != ") == .symbol(matchRange: r(2, 2), replacement: "≠"), "!=")
check(detect("5 +- ") == .symbol(matchRange: r(2, 2), replacement: "±"), "+-")
check(detect("1/2 ") == .symbol(matchRange: r(0, 3), replacement: "½"), "fraction")
check(detect("11/2 ") == nil, "fraction inside a number")
check(detect("1/25 ") == nil, "longer fraction")
check(detect("x->y ") == nil, "arrow inside a word")
check(detect("a->") == nil, "waits for the space")
check(detect("wait... ") == .symbol(matchRange: r(4, 3), replacement: "…"), "ellipsis after a word")
check(detect("wait.... ") == nil, "four dots")
check(detect("$a -> ") == nil, "not inside math")
check(detect("a -> ", [.inline]) == nil, "symbols disabled")

// MARK: - Math spans (live preview)
do {
    let t = "so $x_1 + y" as NSString
    check(MathSpans.span(in: t, at: t.length) ==
          MathSpan(display: false, sourceRange: r(4, 7), fullRange: r(3, 8), closed: false), "open inline span")
    let d = "a $$\\frac{1}{2}$$ b" as NSString
    check(MathSpans.span(in: d, at: 6) ==
          MathSpan(display: true, sourceRange: r(4, 11), fullRange: r(2, 15), closed: true), "closed display span")
    check(MathSpans.span(in: d, at: 18) == nil, "cursor after span")
    let money = "costs $5 and $10" as NSString
    let s = MathSpans.span(in: money, at: 9)
    check(s != nil && MathSpans.looksLikeMoney(money.substring(with: s!.sourceRange)), "money heuristic")
    check(MathSpans.span(in: "a \\$x" as NSString, at: 5) == nil, "escaped dollar")
    check(MathSpans.span(in: "line1 $x\nnext" as NSString, at: 13) == nil, "spans are per line")

    // Editing mid-sentence: the text after the equation stays outside it.
    let mid = "so $x^2 is small.\nnext" as NSString
    let open = MathSpans.span(in: mid, at: 7)!
    check(MathSpans.trimmed(open, in: mid, keepingOutside: " is small.") ==
          MathSpan(display: false, sourceRange: r(4, 3), fullRange: r(3, 4), closed: false), "trimmed: tail kept outside")
    check(MathSpans.trimmed(open, in: mid, keepingOutside: "") == open, "trimmed: empty tail keeps the whole line")
    check(MathSpans.trimmed(open, in: mid, keepingOutside: " is big.") == nil, "trimmed: edited tail no longer matches")
    check(MathSpans.trimmed(open, in: mid, keepingOutside: "so $x^2 is small.") == nil, "trimmed: tail longer than span")
    let reopened = "a $$\\frac{1}{2}, then b" as NSString
    let disp = MathSpans.span(in: reopened, at: 8)!
    check(MathSpans.trimmed(disp, in: reopened, keepingOutside: ", then b")?.sourceRange == r(4, 11), "trimmed: display span")
    check(MathSpans.trimmed(MathSpans.span(in: d, at: 6)!, in: d, keepingOutside: "xyz") ==
          MathSpans.span(in: d, at: 6), "trimmed: closed span unchanged")
}

// MARK: - LaTeX → Unicode examples
for (input, expected) in LatexUnicode.examples {
    let got = LatexUnicode.convert(input)
    check(got == expected, "LatexUnicode(\(input)) = \(got), expected \(expected)")
}
for (input, expected) in LatexUnicode.richExamples {
    let got = LatexUnicode.convertRich(input)
    check(got == expected, "convertRich(\(input)) = \(got.map { "\($0.text)@\($0.level)" }), expected \(expected.map { "\($0.text)@\($0.level)" })")
}
for (input, expected) in LatexUnicode.unicodeRichExamples {
    let got = LatexUnicode.convertRich(input, unicodeScripts: true)
    check(got == expected, "convertRich(\(input), unicodeScripts) = \(got.map { "\($0.text)@\($0.level)\($0.italic ? "i" : "")" })")
}
// In Unicode mode the runs must spell exactly what `convert` produces.
for (input, _) in LatexUnicode.examples {
    let joined = LatexUnicode.convertRich(input, unicodeScripts: true).map(\.text).joined()
    check(joined == LatexUnicode.convert(input), "unicode runs for \(input) spell \(joined)")
}
// Robustness: never crash on junk.
for junk in ["", "\\", "{{{", "}}}", "^", "_", "\\frac", "\\frac{", "\\sqrt[", "x^{", "\\begin{pmatrix}"] {
    _ = LatexUnicode.convert(junk)
}

// MARK: - Style samples (selection toolbar): RTF must round-trip font, size, traits, colour
do {
    let fm = NSFontManager.shared
    func readBack(_ style: CharacterStyle) -> (NSFont?, NSColor?, Int) {
        let a = try? NSAttributedString(data: StyleSample.rtf(style), options: [:], documentAttributes: nil)
        let attrs = a?.attributes(at: 0, effectiveRange: nil) ?? [:]
        return (attrs[.font] as? NSFont, attrs[.foregroundColor] as? NSColor, (attrs[.superscript] as? Int) ?? 0)
    }
    // System font stays the system font (the Helvetica Neue substitution is what this avoids).
    let (f1, c1, _) = readBack(CharacterStyle(font: NSFont.systemFont(ofSize: 22)))
    check(f1.map(StyleSample.isSystem) == true && f1?.pointSize == 22 && c1 == nil, "system 22 round-trips, no colour")
    let boldItalic = StyleSample.systemFace(weight: .bold, italic: true, size: 13)
    let (f2, _, _) = readBack(CharacterStyle(font: boldItalic))
    check(f2.map { StyleSample.isSystem($0) && fm.traits(of: $0).contains([.boldFontMask, .italicFontMask]) } == true,
          "system bold italic round-trips")
    let (f3, c3, s3) = readBack(CharacterStyle(font: NSFont(name: "Palatino-BoldItalic", size: 15)!, color: .systemRed, baseline: 1))
    check(f3?.fontName == "Palatino-BoldItalic" && f3?.pointSize == 15, "Palatino Bold Italic 15 round-trips")
    let red = NSColor.systemRed.usingColorSpace(.sRGB)!
    check(c3.map { c -> Bool in let s = c.usingColorSpace(.sRGB)!
        return abs(s.redComponent - red.redComponent) + abs(s.greenComponent - red.greenComponent)
            + abs(s.blueComponent - red.blueComponent) < 0.01 } == true, "colour round-trips exactly in sRGB")
    check(s3 == 1, "superscript round-trips")
    // Family conversion keeps size and traits.
    let toPal = StyleSample.convert(boldItalic, toFamily: "Palatino")
    check(toPal.fontName == "Palatino-BoldItalic" && toPal.pointSize == 13, "system bold italic → Palatino Bold Italic")
    let back = StyleSample.convert(toPal, toFamily: StyleSample.systemFamilyLabel)
    check(StyleSample.isSystem(back) && fm.traits(of: back).contains([.boldFontMask, .italicFontMask]), "Palatino → system keeps traits")
    let menlo = StyleSample.convert(NSFont.systemFont(ofSize: 14), toFamily: "Menlo")
    check(menlo.familyName == "Menlo" && menlo.pointSize == 14, "system → Menlo")
    check(StyleSample.familyLabel(of: NSFont.systemFont(ofSize: 13)) == "System", "system family label")
    check(StyleSample.scriptSize(base: 10, level: 0) == 10, "script size: base")
    check(abs(StyleSample.scriptSize(base: 10, level: 1) - 7) < 1e-9, "script size: first level 70 %")
    check(abs(StyleSample.scriptSize(base: 10, level: -1) - 7) < 1e-9, "script size: subscript 70 %")
    check(abs(StyleSample.scriptSize(base: 10, level: 2) - 5) < 1e-9, "script size: second level 50 %")
}

// MARK: - File links (shareddocuments://)
do {
    let home = "/Users/me"
    let drive = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
    func url(_ s: String) -> URL { URL(string: s)! }
    let ios = "shareddocuments:///private/var/mobile/Library/Mobile%20Documents/"
    check(FileLinks.macPath(for: url(ios + "com~apple~CloudDocs/a%20b/caf%C3%A9.txt"), home: home) == drive + "/a b/café.txt",
          "file link → Mac path, decoded")
    check(FileLinks.macPath(for: url("shareddocuments:///var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/X"), home: home) == drive + "/X",
          "/var root without /private")
    check(FileLinks.macPath(for: url(ios + "iCloud~md~obsidian/Documents/"), home: home) == "/Users/me/Library/Mobile Documents/iCloud~md~obsidian/Documents",
          "app container, trailing slash")
    check(FileLinks.macPath(for: url(ios + "com~apple~CloudDocs/../../../../etc/passwd"), home: home) == nil, ".. refused")
    check(FileLinks.macPath(for: url(ios), home: home) == nil, "bare Mobile Documents refused")
    check(FileLinks.macPath(for: url("shareddocuments:///etc/passwd"), home: home) == nil, "outside Mobile Documents refused")
    check(FileLinks.macPath(for: url("shareddocuments://private/var/mobile/Library/Mobile%20Documents/x"), home: home) == nil, "host form refused")
    check(FileLinks.macPath(for: url("file:///private/var/mobile/Library/Mobile%20Documents/x"), home: home) == nil, "other scheme refused")
    let link = FileLinks.link(forMacPath: drive + "/Research/a b/café.txt", home: home)
    check(link?.absoluteString == ios + "com~apple~CloudDocs/Research/a%20b/caf%C3%A9.txt", "Mac path → link, encoded")
    check(link.flatMap { FileLinks.macPath(for: $0, home: home) } == drive + "/Research/a b/café.txt", "round trip")
    check(FileLinks.link(forMacPath: "/Users/me/Desktop/x.txt", home: home) == nil, "non-iCloud path refused")
    check(FileLinks.link(forMacPath: drive + "/#1 notes?.txt", home: home)
          .flatMap { FileLinks.macPath(for: $0, home: home) } == drive + "/#1 notes?.txt", "# and ? round trip")
}

// MARK: - Markdown export: equations back to LaTeX
do {
    typealias T = MarkdownEquations.TextEquation
    typealias I = MarkdownEquations.ImageAttachment
    let z = "\u{200B}"
    func restore(_ md: String, _ eqs: [T?], _ images: [I] = []) -> String {
        MarkdownEquations.restore(in: md, textEquations: eqs, images: images)
    }
    let xb2 = T(text: "xb2", source: "x_b^2")
    let ab = T(text: "α + β", source: "\\alpha + \\beta")
    // Lab phase 11 output, verbatim (inside a heading, where Notes writes the italic runs as bold).
    check(restore("# Inline **xb**2\(z) and **α** + **β**\(z) done.  \n", [xb2, ab])
          == "# Inline $x_b^2$ and $\\alpha + \\beta$ done.  \n", "export: lab output, two text equations")
    check(restore("Some bold\(z) words.  \nInline *xb*2\(z) end", [nil, xb2])
          == "Some bold words.  \nInline $x_b^2$ end", "export: bold marker skipped and removed")
    check(restore("so *x*2\(z) and 2*x*\(z).", [T(text: "x2", source: "x^2"), T(text: "2x", source: "2x")])
          == "so $x^2$ and $2x$.", "export: opening delimiter before vs inside")
    check(restore("**word** *y*\(z)", [T(text: "y", source: "y")]) == "**word** $y$", "export: neighbouring bold untouched")
    check(restore("plain xb2\(z) text", [xb2]) == "plain $x_b^2$ text", "export: no emphasis at all")
    check(restore("a <u>xb2</u>\(z)", [xb2]) == "a <u>xb2</u>", "export: unmatched equation left as text")
    check(restore("one\(z) two", [xb2, ab]) == "one two", "export: marker count mismatch leaves text")
    // Images.
    let integral = I(filename: "Pasted Graphic.png", source: "\\int_0^1 f\\,dx")
    check(restore("Display:  \n![Pasted Graphic.png](Pasted%20Graphic.png)  \n\nNext  \n", [], [integral])
          == "Display:  \n$\\int_0^1 f\\,dx$  \n\nNext  \n", "export: image equation on its own line")
    check(restore("# ![Pasted Graphic.png](Pasted%20Graphic.png)  \n", [], [integral])
          == "# $\\int_0^1 f\\,dx$  \n", "export: block prefix counts as its own line")
    check(restore("so ![Pasted Graphic.png](Pasted%20Graphic.png) and more  \n", [], [integral])
          == "so  \n$\\int_0^1 f\\,dx$  \nand more  \n", "export: mid-line image gets its own line")
    let photo = I(filename: "IMG_1.jpeg", source: nil)
    let second = I(filename: "Pasted Graphic 1.png", source: "y")
    check(restore("![IMG_1.jpeg](IMG_1.jpeg)  \n![Pasted Graphic 1.png](Pasted%20Graphic%201.png)  \n", [], [photo, second])
          == "![IMG_1.jpeg](IMG_1.jpeg)  \n$y$  \n", "export: photos kept, equations matched by name")
    check(restore("[file.pdf](file.pdf) ![Pasted Graphic.png](Pasted%20Graphic.png)", [],
                  [I(filename: "file.pdf", source: nil), integral])
          == "[file.pdf](file.pdf)  \n$\\int_0^1 f\\,dx$", "export: non-image attachment skipped")
    check(restore("x ![a.png](a.png)", [], [I(filename: "b.png", source: "z")]) == "x ![a.png](a.png)",
          "export: unknown image untouched")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
