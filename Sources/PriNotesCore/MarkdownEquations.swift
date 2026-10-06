import Foundation

/// Puts the LaTeX of Pri Notes equations back into the Markdown that Notes' own
/// Edit ▸ Copy as Markdown produces, for the note footer's export button.
///
/// Notes exports a text equation as its converted characters, with emphasis markers wherever the
/// Palatino Italic and Roman runs alternate, and keeps the invisible U+200B that ends every text
/// equation. An image equation becomes `![Pasted Graphic.png](Pasted%20Graphic.png)` (verified in
/// lab phase 11):
///
///     Inline **xb**2​ and **α** + **β**​ done.        (the U+200B follows "2" and the last "**")
///     ![Pasted Graphic.png](Pasted%20Graphic.png)
///
/// `restore` turns that into:
///
///     Inline $x_b^2$ and $\alpha + \beta$ done.
///     $\int_0^1 f\,dx$
///
/// Every equation becomes inline `$…$`. Equations that were images also get a line of their own.
/// U+200B markers that aren't equations (left by `**bold**` conversions) are removed.
///
/// Example:
/// ```swift
/// let md = "Inline **xb**2\u{200B} done.  \n![Pasted Graphic.png](Pasted%20Graphic.png)  \n"
/// MarkdownEquations.restore(in: md,
///     textEquations: [.init(text: "xb2", source: "x_b^2")],
///     images: [.init(filename: "Pasted Graphic.png", source: "\\int_0^1 f\\,dx")])
/// // "Inline $x_b^2$ done.  \n$\int_0^1 f\,dx$  \n"
/// ```
public enum MarkdownEquations {
    /// A text equation in the note: its converted characters and its LaTeX.
    public struct TextEquation: Equatable {
        public let text: String
        public let source: String
        public init(text: String, source: String) {
            self.text = text
            self.source = source
        }
    }

    /// An attachment in the note's rich text copy: its file name and, for an equation image, its LaTeX.
    public struct ImageAttachment: Equatable {
        public let filename: String
        public let source: String?
        public init(filename: String, source: String?) {
            self.filename = filename
            self.source = source
        }
    }

    static let marker: Unicode.Scalar = "\u{200B}"
    /// Characters Notes uses for emphasis (`**bold**`, `*italic*`, `~~strike~~`).
    static let delimiters: Set<Unicode.Scalar> = ["*", "_", "~"]

    /// Replace the equations in `markdown` with `$source$`.
    ///
    /// - Parameters:
    ///   - textEquations: one entry per U+200B in the note's text, in order; nil where the marker
    ///     doesn't end an equation. If Notes' Markdown holds a different number of markers, the
    ///     mapping isn't trusted and the text equations are left as Notes wrote them.
    ///   - images: the note's attachments in order. Each `![name](…)` is matched to the next
    ///     attachment with that file name; those with a source become `$source$` on their own line,
    ///     the others (photos, files) stay as Notes wrote them.
    public static func restore(in markdown: String, textEquations: [TextEquation?], images: [ImageAttachment]) -> String {
        var result = restoreTextEquations(in: markdown, textEquations)
        result = restoreImages(in: result, images)
        result.unicodeScalars.removeAll { $0 == marker }
        return result
    }

    /// Text equations: for the k-th marker, walk back from it, matching the equation's characters in
    /// reverse and stepping over emphasis delimiters, then replace that stretch and the marker.
    ///
    /// An odd number of delimiter runs inside the stretch means the first one closes a run that
    /// opened just before the equation (`**xb**2`), so that opening run is replaced too.
    /// An equation whose characters can't be matched (e.g. underlined, which Notes writes as HTML)
    /// is left alone.
    static func restoreTextEquations(in markdown: String, _ equations: [TextEquation?]) -> String {
        var md = Array(markdown.unicodeScalars)
        let markers = md.indices.filter { md[$0] == marker }
        guard markers.count == equations.count, equations.contains(where: { $0 != nil }) else { return markdown }

        // Right to left, so earlier indices stay valid.
        for k in markers.indices.reversed() {
            guard let equation = equations[k] else { continue }
            let end = markers[k]
            let floor = k > 0 ? markers[k - 1] + 1 : 0
            var j = end - 1
            var matched = true
            for scalar in equation.text.unicodeScalars.reversed() {
                while j >= floor, md[j] != scalar, delimiters.contains(md[j]) { j -= 1 }
                guard j >= floor, md[j] == scalar else { matched = false; break }
                j -= 1
            }
            guard matched else { continue }

            var start = j + 1
            var runs = 0
            var previous: Unicode.Scalar?
            for scalar in md[start..<end] {
                if delimiters.contains(scalar), scalar != previous { runs += 1 }
                previous = delimiters.contains(scalar) ? scalar : nil
            }
            if runs % 2 == 1, start > floor, delimiters.contains(md[start - 1]) {
                let opener = md[start - 1]
                while start > floor, md[start - 1] == opener { start -= 1 }
            }
            md.replaceSubrange(start...end, with: "$\(equation.source)$".unicodeScalars)
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: md)
        return String(out)
    }

    /// Image equations: `![name](…)` → `$source$` on its own line.
    ///
    /// Notes ends every line with two spaces (a Markdown line break), so the same is used when a
    /// break has to be added before or after the equation. A line that holds only block markers
    /// (`# `, `- `, `> `, `1. `) before the image counts as the equation's own line.
    static func restoreImages(in markdown: String, _ images: [ImageAttachment]) -> String {
        guard images.contains(where: { $0.source != nil }),
              let imageToken = try? NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]*)\)"#),
              let blockPrefix = try? NSRegularExpression(pattern: #"^\s*(#{1,6}|>+|[-*+]|\d+[.)]|- \[[ xX]\])?\s*$"#)
        else { return markdown }
        let text = markdown as NSString

        // Pair each image token with its attachment, in order.
        var replacements: [(range: NSRange, source: String)] = []
        var next = 0
        for match in imageToken.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            let alt = text.substring(with: match.range(at: 1))
            let url = text.substring(with: match.range(at: 2)).removingPercentEncoding ?? ""
            guard let found = images[next...].firstIndex(where: { $0.filename == alt || (!$0.filename.isEmpty && $0.filename == url) })
            else { continue }
            next = found + 1
            if let source = images[found].source { replacements.append((match.range, source)) }
        }

        let result = NSMutableString(string: markdown)
        for (range, source) in replacements.reversed() {
            let line = text.lineRange(for: range)
            var lineEnd = NSMaxRange(line)
            while lineEnd > line.location, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
            let before = text.substring(with: NSRange(location: line.location, length: range.location - line.location))
            let after = text.substring(with: NSRange(location: NSMaxRange(range), length: lineEnd - NSMaxRange(range)))
            let ownStart = blockPrefix.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
            let ownEnd = after.allSatisfy { $0 == " " || $0 == "\t" }

            var replaced = range
            var replacement = "$\(source)$"
            if !ownStart {
                // Swallow the spaces before the image; the break replaces them.
                while replaced.location > line.location, text.character(at: replaced.location - 1) == 0x20 {
                    replaced = NSRange(location: replaced.location - 1, length: replaced.length + 1)
                }
                replacement = "  \n" + replacement
            }
            if !ownEnd {
                while NSMaxRange(replaced) < lineEnd, text.character(at: NSMaxRange(replaced)) == 0x20 {
                    replaced.length += 1
                }
                replacement += "  \n"
            }
            result.replaceCharacters(in: replaced, with: replacement)
        }
        return result as String
    }
}
