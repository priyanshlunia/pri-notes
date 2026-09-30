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

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
