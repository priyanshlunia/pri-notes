import Foundation

/// Paragraph-level Apple Notes styles reachable from the Format menu.
public enum BlockStyle: String, CaseIterable {
    case title, heading, subheading, monostyled, checklist, blockQuote
}

/// Character-level styles that Apple Notes toggles from Format ▸ Font.
public enum InlineStyle: String, CaseIterable {
    case bold, italic, underline, strikethrough
}

/// Which families of rules are active (toggled from the menu-bar menu).
public struct RuleSet: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let blocks       = RuleSet(rawValue: 1 << 0)
    public static let inline       = RuleSet(rawValue: 1 << 1)
    public static let links        = RuleSet(rawValue: 1 << 2)
    public static let unicodeMath  = RuleSet(rawValue: 1 << 3)
    public static let renderedMath = RuleSet(rawValue: 1 << 4)
    public static let symbols      = RuleSet(rawValue: 1 << 5)
    public static let all: RuleSet = [.blocks, .inline, .links, .unicodeMath, .renderedMath, .symbols]
}

/// What to do to the note once a Markdown pattern has been completed.
///
/// All ranges are absolute UTF-16 offsets into the text area's value — the same
/// units the Accessibility API (`AXSelectedTextRange`) and `NSString` use.
public enum Action: Equatable {
    /// Delete `prefixRange` (e.g. "## ") and apply a paragraph style.
    case block(BlockStyle, prefixRange: NSRange)
    /// Replace `matchRange` (e.g. "**word**") with `inner`, then style `inner`.
    case inline(InlineStyle, matchRange: NSRange, inner: String)
    /// Replace `matchRange` ("`code` " incl. the trailing space) with monospaced `inner` + plain space.
    case code(matchRange: NSRange, inner: String)
    /// Replace `matchRange` ("[text](url) " incl. the trailing space) with a link + plain space.
    case link(matchRange: NSRange, text: String, url: String)
    /// Replace `matchRange` ("$…$") with Unicode math text.
    case unicodeMath(matchRange: NSRange, latex: String)
    /// Replace `matchRange` ("$$…$$") with a typeset image.
    case renderedMath(matchRange: NSRange, latex: String)
    /// Replace `matchRange` (e.g. "->", without the space typed after it) with `replacement` ("→").
    case symbol(matchRange: NSRange, replacement: String)
}

/// Detects completed Markdown patterns immediately before the insertion point.
///
/// The detector is deliberately stateless: after every trigger keystroke the app
/// reads the whole note text plus the cursor position, and asks
/// `Rules.detect(in:cursor:enabled:)` whether the text *ending at the cursor*
/// completes a pattern. Only the current line (text since the last newline) is
/// examined, so patterns never span paragraphs.
///
/// Example:
/// ```swift
/// let text = "Intro\n## " as NSString
/// Rules.detect(in: text, cursor: text.length, enabled: .all)
/// // → .block(.heading, prefixRange: NSRange(location: 6, length: 3))
/// ```
public enum Rules {

    /// Characters whose keystroke can complete a pattern. Other keystrokes are ignored
    /// without touching the Accessibility API.
    public static let triggerCharacters: Set<Character> = [" ", "*", "_", "~", "$", "`"]

    /// Smart symbols typed outside math, converted on the space after them. Longer sequences come
    /// first so "<->" isn't read as "<-" followed by ">".
    public static let symbols: [(sequence: String, symbol: String)] = [
        ("<->", "↔"), ("<=>", "⇔"), ("->", "→"), ("<-", "←"), ("=>", "⇒"),
        ("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("+-", "±"), ("-+", "∓"), ("~=", "≈"),
        ("1/2", "½"), ("1/3", "⅓"), ("2/3", "⅔"), ("1/4", "¼"), ("3/4", "¾"),
        ("...", "…"),
    ]

    private struct Pattern {
        let family: RuleSet
        let regex: NSRegularExpression
        /// Builds the action from the match (line-relative ranges) and the line's absolute start offset.
        let make: (NSTextCheckingResult, NSString, Int) -> Action
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// Ordered from most to least specific: the first matching pattern wins.
    /// Every pattern is anchored with `$` so it must end exactly at the cursor.
    private static let patterns: [Pattern] = {
        func shift(_ r: NSRange, _ by: Int) -> NSRange { NSRange(location: r.location + by, length: r.length) }

        func blockPattern(_ regex: String, _ style: BlockStyle) -> Pattern {
            Pattern(family: .blocks, regex: re(regex)) { m, _, start in
                .block(style, prefixRange: shift(m.range, start))
            }
        }
        func inlinePattern(_ regex: String, _ style: InlineStyle) -> Pattern {
            Pattern(family: .inline, regex: re(regex)) { m, line, start in
                .inline(style, matchRange: shift(m.range, start), inner: line.substring(with: m.range(at: 1)))
            }
        }

        func symbolPattern() -> Pattern {
            let escaped = symbols.filter { $0.sequence != "..." }
                .map { NSRegularExpression.escapedPattern(for: $0.sequence) }.joined(separator: "|")
            let table = Dictionary(uniqueKeysWithValues: symbols.map { ($0.sequence, $0.symbol) })
            return Pattern(family: .symbols, regex: re("(?:(?:^|(?<=\\s))(" + escaped + ")|(?<!\\.)(\\.\\.\\.)) $")) { m, line, start in
                let group = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
                return .symbol(matchRange: shift(group, start), replacement: table[line.substring(with: group)]!)
            }
        }

        return [
            // --- Paragraph styles: the marker must be the whole line so far.
            blockPattern(#"^# $"#, .title),
            blockPattern(#"^## $"#, .heading),
            blockPattern(#"^### $"#, .subheading),
            blockPattern(#"^```$"#, .monostyled),
            blockPattern(#"^\[ ?\] $"#, .checklist),
            blockPattern(#"^> $"#, .blockQuote),

            // --- Links convert on the space after ")" so the link attribute doesn't leak into later typing.
            Pattern(family: .links, regex: re(#"(?<!!)\[([^\[\]]+)\]\(([^()\s]+)\) $"#)) { m, line, start in
                .link(matchRange: shift(m.range, start),
                      text: line.substring(with: m.range(at: 1)),
                      url: line.substring(with: m.range(at: 2)))
            },

            // --- Math. $$…$$ must be tested before $…$.
            Pattern(family: .renderedMath, regex: re(#"(?<![$\\])\$\$([^$]*[^\s$\\][^$]*)\$\$$"#)) { m, line, start in
                .renderedMath(matchRange: shift(m.range, start),
                              latex: line.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
            },
            // Opening "$" must be followed by non-space and closing "$" preceded by non-space
            // (pandoc's rule) so prices like "$5 and $10" don't trigger.
            Pattern(family: .unicodeMath, regex: re(#"(?<![$\\])\$(?=[^\s$])([^$]*[^\s$\\])\$$"#)) { m, line, start in
                .unicodeMath(matchRange: shift(m.range, start), latex: line.substring(with: m.range(at: 1)))
            },

            // --- Inline code converts on the following space, like links.
            Pattern(family: .inline, regex: re(#"(?<!`)`([^`]+)` $"#)) { m, line, start in
                .code(matchRange: shift(m.range, start), inner: line.substring(with: m.range(at: 1)))
            },

            // --- Emphasis. Openers may not follow a word character (so snake_case and 2*3*4 survive).
            inlinePattern(#"(?<![\w*\\])\*\*(?=\S)((?:(?!\*\*).)+?)(?<=\S)\*\*$"#, .bold),
            inlinePattern(#"(?<![\w_\\])__(?=\S)((?:(?!__).)+?)(?<=\S)__$"#, .underline),
            inlinePattern(#"(?<![\w~\\])~~(?=\S)((?:(?!~~).)+?)(?<=\S)~~$"#, .strikethrough),
            inlinePattern(#"(?<![\w*\\])\*(?=[^\s*])([^*]*?[^\s*])\*$"#, .italic),
            inlinePattern(#"(?<![\w_\\])_(?=[^\s_])([^_]*?[^\s_])_$"#, .italic),

            // --- Smart symbols, on the space after them. A sequence must start a word ("a -> b",
            // not "x->y" or "11/2"), except "..." which usually follows one ("wait... ").
            symbolPattern(),
        ]
    }()

    /// Returns the action for the pattern completed at `cursor`, or `nil`.
    ///
    /// - Parameters:
    ///   - text: The full text of the note body (as read from `AXValue`).
    ///   - cursor: Insertion point, in UTF-16 units.
    ///   - enabled: Families of rules currently switched on.
    public static func detect(in text: NSString, cursor: Int, enabled: RuleSet) -> Action? {
        guard cursor > 0, cursor <= text.length else { return nil }
        let before = text.substring(to: cursor) as NSString
        let newline = before.range(of: "\n", options: .backwards)
        let lineStart = newline.location == NSNotFound ? 0 : newline.location + 1
        let line = before.substring(from: lineStart) as NSString
        guard line.length > 0 else { return nil }
        let whole = NSRange(location: 0, length: line.length)

        let mathFamilies: RuleSet = [.unicodeMath, .renderedMath]
        for pattern in patterns where enabled.contains(pattern.family) {
            guard let m = pattern.regex.firstMatch(in: line as String, options: [], range: whole) else { continue }
            // Inside $…$ the characters _ * ~ ` belong to LaTeX, not Markdown.
            if mathFamilies.isDisjoint(with: pattern.family),
               MathSpans.span(in: text, at: lineStart + m.range.location) != nil { continue }
            return pattern.make(m, line, lineStart)
        }
        return nil
    }
}
