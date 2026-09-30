import Foundation

/// A `$…$` or `$$…$$` span on one line of a note.
public struct MathSpan: Equatable {
    /// True for `$$…$$` (rendered image), false for `$…$` (Unicode text).
    public var display: Bool
    /// The LaTeX between the delimiters (absolute range; excludes the delimiters).
    public var sourceRange: NSRange
    /// Opening delimiter through closing delimiter, or through the end of the line if unclosed.
    public var fullRange: NSRange
    /// Whether the closing delimiter has been typed.
    public var closed: Bool

    public init(display: Bool, sourceRange: NSRange, fullRange: NSRange, closed: Bool) {
        self.display = display
        self.sourceRange = sourceRange
        self.fullRange = fullRange
        self.closed = closed
    }
}

/// Locates math spans on a line so the app can (a) show a live preview while the cursor is
/// inside an unfinished `$…` / `$$…`, and (b) avoid treating `_` or `*` inside math as Markdown.
///
/// Delimiter rules match `Rules`: `\$` is literal; `$` opens inline math only when followed by a
/// non-space; it closes only when preceded by a non-space; `$$` opens/closes display math.
///
/// Example:
/// ```swift
/// let text = "so $x_1 + y" as NSString
/// MathSpans.span(in: text, at: text.length)
/// // → MathSpan(display: false, sourceRange: {4, 7}, fullRange: {3, 8}, closed: false)
/// ```
public enum MathSpans {

    /// All math spans on the line containing `location`.
    public static func spans(onLineOf text: NSString, at location: Int) -> [MathSpan] {
        let loc = min(max(0, location), text.length)
        let lineRange = text.lineRange(for: NSRange(location: loc, length: 0))
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, let c = UnicodeScalar(text.character(at: end - 1)),
              CharacterSet.newlines.contains(c) { end -= 1 }

        func char(_ i: Int) -> unichar? { i >= lineRange.location && i < end ? text.character(at: i) : nil }
        let dollar = unichar(UInt8(ascii: "$")), backslash = unichar(UInt8(ascii: "\\"))
        func isSpace(_ c: unichar?) -> Bool {
            guard let c, let s = UnicodeScalar(c) else { return true }
            return CharacterSet.whitespaces.contains(s)
        }

        var result: [MathSpan] = []
        var open: (start: Int, display: Bool)?
        var i = lineRange.location
        while i < end {
            let c = text.character(at: i)
            if c == backslash { i += 2; continue }           // skip escaped char (incl. \$)
            guard c == dollar else { i += 1; continue }
            let isDouble = char(i + 1) == dollar
            if let o = open {
                if o.display && isDouble {
                    result.append(MathSpan(display: true,
                                           sourceRange: NSRange(location: o.start + 2, length: i - o.start - 2),
                                           fullRange: NSRange(location: o.start, length: i + 2 - o.start), closed: true))
                    open = nil; i += 2; continue
                }
                if !o.display && !isSpace(char(i - 1)) {
                    result.append(MathSpan(display: false,
                                           sourceRange: NSRange(location: o.start + 1, length: i - o.start - 1),
                                           fullRange: NSRange(location: o.start, length: i + 1 - o.start), closed: true))
                    open = nil; i += 1; continue
                }
                i += isDouble ? 2 : 1
            } else if isDouble {
                open = (i, true); i += 2
            } else if !isSpace(char(i + 1)) {
                open = (i, false); i += 1
            } else {
                i += 1
            }
        }
        if let o = open {
            let startOfSource = o.start + (o.display ? 2 : 1)
            result.append(MathSpan(display: o.display,
                                   sourceRange: NSRange(location: startOfSource, length: end - startOfSource),
                                   fullRange: NSRange(location: o.start, length: end - o.start), closed: false))
        }
        return result
    }

    /// The span whose source contains `location` (cursor between the delimiters), if any.
    public static func span(in text: NSString, at location: Int) -> MathSpan? {
        spans(onLineOf: text, at: location).first { span in
            location >= span.sourceRange.location && location <= NSMaxRange(span.sourceRange)
        }
    }

    /// True if an unfinished inline `$` span looks like a price ("$5 and …") rather than math,
    /// so the live preview stays quiet while typing about money.
    public static func looksLikeMoney(_ source: String) -> Bool {
        source.range(of: #"^\d+([.,]\d+)*(\s|$)"#, options: .regularExpression) != nil
    }
}
