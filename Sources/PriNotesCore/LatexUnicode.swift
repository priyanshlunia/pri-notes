import Foundation

/// A piece of converted math text at one baseline level.
public struct MathRun: Equatable {
    public var text: String
    /// 0 = baseline, +1 = superscript, −1 = subscript; nesting accumulates
    /// (level = parent level + 1 for `^`, − 1 for `_`).
    public var level: Int
    /// True for text that LaTeX would typeset in math italic (Latin letters, lowercase Greek).
    public var italic: Bool
    public init(text: String, level: Int, italic: Bool = false) {
        self.text = text
        self.level = level
        self.italic = italic
    }
}

/// Converts a LaTeX math-mode snippet (the text between single `$...$` typed in
/// Apple Notes) into plain Unicode text that reads like math.
///
/// The converter is a small recursive-descent parser. Input is read as a stream of
/// "atoms": a single character, a `{...}` group, or a `\command` together with its
/// arguments. `^` and `_` take the next atom as their argument.
///
/// Examples:
/// ```
/// LatexUnicode.convert("\\alpha^2 + \\beta_1")   // "α² + β₁"
/// LatexUnicode.convert("\\frac{a+b}{2}")         // "(a + b)/2"
/// LatexUnicode.convert("\\frac{1}{2}")           // "½"
/// LatexUnicode.convert("e^{-x^2}")               // "e⁻ˣ²"
/// LatexUnicode.convert("x_{i,j}")                // "x_(i,j)"   (comma has no subscript form)
/// LatexUnicode.convert("\\mathbb{R}^n")          // "ℝⁿ"
/// LatexUnicode.convert("\\sqrt[3]{x+1}")         // "∛(x + 1)"
/// ```
///
/// Design notes:
/// * Superscripts/subscripts: the argument is converted first; if every resulting
///   character has a Unicode script form the compact form is emitted, otherwise the
///   fallback `^(...)` / `_(...)` is used (parentheses omitted for a single character).
///   Inside scripts no spaces are inserted around operators.
/// * Binary relations, arrows, `+`, `−`, `±`, `⋅`, `×`, `÷` get a single space on each
///   side (when binary). Inside `\frac` arguments spacing is applied as usual, so
///   `\frac{a+b}{2}` gives `(a + b)/2`; the numerator/denominator is wrapped in
///   parentheses if it contains a space, `+`, `−`, `-`, `⋅`, `×` or `/`.
/// * The function never throws and never traps: unknown commands are emitted without
///   the backslash, unbalanced braces are closed at end of input, and nesting is
///   depth-limited.
public enum LatexUnicode {

    /// Convert a LaTeX math-mode snippet into Unicode text. Never throws; unknown
    /// commands are emitted without the backslash (e.g. `\foo` → `foo`).
    /// Example: LatexUnicode.convert("\\frac{a+b}{2}") == "(a + b)/2"
    public static func convert(_ latex: String) -> String {
        let parser = Parser(latex, rich: false)
        let raw = parser.parseSequence(spaced: true, closeOnBrace: false, singleAtom: false, cellMode: false)
        return finish(raw).map { $0.text }.joined()
    }

    /// Convert to runs for rich-text insertion: script arguments are emitted as runs at a
    /// shifted level (never converted to Unicode ²/₁ characters and never wrapped in ^(…)/_(…)).
    /// Level = parent level + 1 for `^`, − 1 for `_`, so `x^{a^b}` gives x@0 a@1 b@2 and
    /// `x_{i_j}` gives x@0 i@-1 j@-2. Exceptions that stay at the current level as Unicode:
    /// `^\prime`, `^{\prime}`, `'` → ′ and `^\circ` → °. Adjacent runs with equal level are
    /// merged and empty runs dropped. Composite commands (`\frac`, `\sqrt`, `\binom`,
    /// environments, font/text commands) splice their arguments' runs into the output with
    /// levels and italics kept, so scripts inside them stay level runs and
    /// `e^{\frac{a}{b}}` gives e@0 a@1 "/"@1 b@1.
    /// Each run carries an `italic` flag following LaTeX math conventions: Latin letters and
    /// lowercase Greek are italic; digits, operators, symbols, uppercase Greek, function names
    /// and \mathrm/\text/\mathbf/\mathbb/... contents are upright (\mathit and \textit give
    /// italic letters). Accents take the italic value of their base; spaces join the run before.
    /// With `unicodeScripts: true` every run is at level 0 and scripts become Unicode
    /// super/subscript characters (or the `^(...)`/`_(...)` fallback), so the concatenated text
    /// equals `convert(latex)`; only the italic/upright split is added.
    /// Example: convertRich("B_\\phi^2") == [MathRun(text: "B", level: 0), MathRun(text: "ϕ", level: -1), MathRun(text: "2", level: 1)]
    public static func convertRich(_ latex: String, unicodeScripts: Bool = false) -> [MathRun] {
        let parser = Parser(latex, rich: !unicodeScripts)
        let raw = parser.parseSequence(spaced: true, closeOnBrace: false, singleAtom: false, cellMode: false)
        return finish(raw)
    }

    /// Final clean-up shared by `convert` and `convertRich`: collapse runs of ASCII spaces
    /// (even across run boundaries), trim whitespace at both ends, give every space the
    /// italic value of the character before it (or of the one after it when the space
    /// starts a level, so spaces never split runs), turn the `\quad` placeholder (U+E000)
    /// into a real space, then merge neighbours with equal level and italic.
    fileprivate static func finish(_ runs: [MathRun]) -> [MathRun] {
        var chars: [(ch: Character, level: Int, italic: Bool)] = []
        var lastWasSpace = false
        for run in runs {
            for ch in run.text {
                if ch == " " {
                    if !lastWasSpace { chars.append((ch, run.level, run.italic)) }
                    lastWasSpace = true
                } else {
                    chars.append((ch, run.level, run.italic))
                    lastWasSpace = false
                }
            }
        }
        while let first = chars.first, first.ch.isWhitespace { chars.removeFirst() }
        while let last = chars.last, last.ch.isWhitespace { chars.removeLast() }

        for i in chars.indices where chars[i].ch == " " || chars[i].ch == "\u{E000}" {
            if i > 0, chars[i - 1].level == chars[i].level {
                chars[i].italic = chars[i - 1].italic
            } else if i + 1 < chars.count, chars[i + 1].level == chars[i].level {
                var j = i + 1
                while j + 1 < chars.count, chars[j].ch == " ", chars[j + 1].level == chars[j].level { j += 1 }
                chars[i].italic = chars[j].italic
            }
        }

        var result: [MathRun] = []
        for (ch, level, italic) in chars {
            let out = (ch == "\u{E000}") ? " " : String(ch)
            if let last = result.last, last.level == level, last.italic == italic {
                result[result.count - 1].text += out
            } else {
                result.append(MathRun(text: out, level: level, italic: italic))
            }
        }
        return result
    }

    // MARK: - Tables

    /// Kind of the most recently emitted item; decides whether `+`/`−` are binary.
    fileprivate enum Prev { case start, operand, op, open }

    fileprivate static let symbols: [String: String] = [
        // Lowercase Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "varkappa": "ϰ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Uppercase Greek
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Big operators / calculus
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "sum": "∑", "prod": "∏",
        "partial": "∂", "nabla": "∇", "infty": "∞",
        // Arithmetic
        "pm": "±", "mp": "∓", "times": "×", "cdot": "⋅", "div": "÷",
        // Relations
        "leq": "≤", "le": "≤", "leqslant": "≤", "geq": "≥", "ge": "≥", "geqslant": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅",
        "equiv": "≡", "propto": "∝", "ll": "≪", "gg": "≫",
        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "leftrightarrow": "↔", "mapsto": "↦",
        "implies": "⟹", "iff": "⟺", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "Longrightarrow": "⟹", "Longleftarrow": "⟸", "longmapsto": "⟼", "rightleftharpoons": "⇌",
        "uparrow": "↑", "downarrow": "↓",
        // Sets and logic
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
        "supseteq": "⊇", "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅",
        "setminus": "∖", "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨", "therefore": "∴", "because": "∵",
        // Misc operators and letters
        "oplus": "⊕", "otimes": "⊗", "odot": "⊙", "circ": "∘", "bullet": "∙", "star": "⋆", "ast": "∗",
        "dagger": "†", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "mid": "∣", "vert": "|", "lvert": "|", "rvert": "|",
        "Vert": "‖", "lVert": "‖", "rVert": "‖", "|": "‖",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "lbrace": "{", "rbrace": "}", "{": "{", "}": "}",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "degree": "°", "prime": "′", "backslash": "\\", "square": "□", "triangle": "△",
        // Escaped literal characters
        "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
    ]

    /// Symbols that are spaced like binary operators / relations.
    fileprivate static let spacedSymbols: Set<String> = [
        "≤", "≥", "≠", "≈", "∼", "≃", "≅", "≡", "∝", "≪", "≫",
        "→", "←", "⇒", "⇐", "⇔", "↔", "↦", "⟹", "⟺", "⟶", "⟵", "⟸", "⟼", "⇌",
        "∈", "∉", "∋", "⊂", "⊆", "⊃", "⊇", "⋅", "×", "÷",
    ]

    /// Prefix-like symbols: what follows them is not "after an operand" (so `-x` is unary).
    fileprivate static let prefixSymbols: Set<String> = [
        "∫", "∬", "∭", "∮", "∑", "∏", "∇", "∂", "¬", "∀", "∃",
    ]

    fileprivate static let functionNames: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cot", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "log", "ln", "exp", "lim", "max", "min", "sup", "inf",
        "det", "dim", "ker", "deg", "arg", "gcd", "Pr",
    ]

    /// Commands that are silently dropped.
    fileprivate static let ignoredCommands: Set<String> = [
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits",
        "hline", "nonumber", "notag",
    ]

    /// `\left`, `\right`, `\big` and friends: dropped, keeping the delimiter that follows.
    fileprivate static let sizingCommands: Set<String> = [
        "left", "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "Biggl", "Biggr",
    ]

    /// Commands whose brace argument is copied verbatim (spaces kept).
    fileprivate static let rawTextCommands: Set<String> = [
        "text", "textrm", "mbox", "hbox", "textbf", "textit", "textsf", "texttt", "textnormal",
    ]

    /// Commands whose (converted) argument is emitted unchanged.
    fileprivate static let plainFontCommands: Set<String> = [
        "mathrm", "mathit", "mathsf", "mathtt", "operatorname", "operatorname*",
    ]

    fileprivate static let styledFontCommands: Set<String> = [
        "mathbb", "mathcal", "mathscr", "mathfrak", "mathbf", "boldsymbol", "bm",
    ]

    fileprivate static let accentMarks: [String: String] = [
        "hat": "\u{302}", "widehat": "\u{302}", "tilde": "\u{303}", "widetilde": "\u{303}",
        "vec": "\u{20D7}", "dot": "\u{307}", "ddot": "\u{308}", "acute": "\u{301}",
        "grave": "\u{300}", "breve": "\u{306}", "check": "\u{30C}",
        "bar": "\u{305}", "overline": "\u{305}", "underline": "\u{332}",
    ]

    /// Accents that go after every character rather than only the last one.
    fileprivate static let everyCharAccents: Set<String> = ["bar", "overline", "underline"]

    fileprivate static let vulgarFractions: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "2/5": "⅖",
        "3/5": "⅗", "4/5": "⅘", "1/6": "⅙", "5/6": "⅚", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
    ]

    /// Superscript forms. Already-superscript characters map to themselves (so nested
    /// scripts like `e^{-x^2}` work), as do `′` and `°`.
    fileprivate static let superscripts: [Character: Character] = {
        var table: [Character: Character] = [:]
        let plain = Array("0123456789+−=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVWβγδθιφχ")
        let script = Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂᵝᵞᵟᶿᶥᵠᵡ")
        for (p, s) in zip(plain, script) {
            table[p] = s
            table[s] = s
        }
        table["′"] = "′"
        table["°"] = "°"
        return table
    }()

    /// Subscript forms (already-subscript characters map to themselves).
    fileprivate static let subscripts: [Character: Character] = {
        var table: [Character: Character] = [:]
        let plain = Array("0123456789+−=()aehijklmnoprstuvxβγρφχ")
        let script = Array("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵦᵧᵨᵩᵪ")
        for (p, s) in zip(plain, script) {
            table[p] = s
            table[s] = s
        }
        return table
    }()

    /// Map text to a Unicode math alphabet. `font` is one of the styled font command names.
    fileprivate static func styled(_ text: String, font: String) -> String {
        let blackboardHoles: [String: UInt32] = ["C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119,
                                                 "Q": 0x211A, "R": 0x211D, "Z": 0x2124]
        let scriptHoles: [String: UInt32] = ["B": 0x212C, "E": 0x2130, "F": 0x2131, "H": 0x210B,
                                             "I": 0x2110, "L": 0x2112, "M": 0x2133, "R": 0x211B]
        let frakturHoles: [String: UInt32] = ["C": 0x212D, "H": 0x210C, "I": 0x2111, "R": 0x211C, "Z": 0x2128]

        var result = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let letter = String(scalar)
            let isUpper = v >= 65 && v <= 90
            let isLower = v >= 97 && v <= 122
            let isDigit = v >= 48 && v <= 57
            var mapped: UInt32? = nil
            switch font {
            case "mathbb":
                if isUpper { mapped = blackboardHoles[letter] ?? (0x1D538 + v - 65) }
                else if isLower { mapped = 0x1D552 + v - 97 }
                else if isDigit { mapped = 0x1D7D8 + v - 48 }
            case "mathcal", "mathscr":
                if isUpper { mapped = scriptHoles[letter] ?? (0x1D49C + v - 65) }
            case "mathfrak":
                if isUpper { mapped = frakturHoles[letter] ?? (0x1D504 + v - 65) }
                else if isLower { mapped = 0x1D51E + v - 97 }
            default: // bold
                if isUpper { mapped = 0x1D400 + v - 65 }
                else if isLower { mapped = 0x1D41A + v - 97 }
                else if isDigit { mapped = 0x1D7CE + v - 48 }
            }
            if let m = mapped, let out = Unicode.Scalar(m) {
                result.unicodeScalars.append(out)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Output buffer

    /// Accumulates output runs for one sequence, tracking spacing state.
    fileprivate struct Buffer {
        /// Output so far; adjacent runs with equal level are merged.
        var runs: [MathRun] = []
        var prev: Prev = .start
        /// A source whitespace run was seen; a single space is inserted before the next item.
        var pending = false
        /// Whether operators receive surrounding spaces (false inside scripts).
        var spaced: Bool

        /// Last character emitted so far (nil if nothing yet).
        var lastChar: Character? { runs.last?.text.last }

        /// Append text at `level` (relative to this sequence), merging with an equal-level,
        /// equal-italic last run.
        mutating func append(_ text: String, level: Int = 0, italic: Bool = false) {
            if text.isEmpty { return }
            if let last = runs.last, last.level == level, last.italic == italic {
                runs[runs.count - 1].text += text
            } else {
                runs.append(MathRun(text: text, level: level, italic: italic))
            }
        }

        /// Append `text`, first flushing any pending source whitespace as one space.
        mutating func emit(_ text: String, _ kind: Prev, level: Int = 0, italic: Bool = false) {
            if text.isEmpty { return }
            if pending {
                // No space inside scripts, or right after an opening bracket.
                if spaced, let last = lastChar, last != " ", last != "(", last != "[" {
                    append(" ")
                }
                pending = false
            }
            append(text, level: level, italic: italic)
            prev = kind
        }

        /// Append already-built runs (keeping their levels and italics).
        mutating func emitRuns(_ list: [MathRun], _ kind: Prev) {
            for run in list { emit(run.text, kind, level: run.level, italic: run.italic) }
        }

        /// Append plain text one character at a time; letters are italic only if `italicLetters`.
        mutating func emitText(_ text: String, italicLetters: Bool, level: Int = 0) {
            for ch in text { emit(String(ch), .operand, level: level, italic: italicLetters && ch.isLetter) }
        }

        /// Append an operator. Binary operators get a space on each side (when `spaced`).
        mutating func emitOperator(_ op: String, binary: Bool) {
            if binary && spaced {
                if let last = lastChar, last != " " { append(" ") }
                append(op + " ")
                pending = false
                prev = .op
            } else {
                emit(op, .op)
            }
        }
    }

    // MARK: - Parser

    fileprivate final class Parser {
        let chars: [Character]
        var pos = 0
        var depth = 0
        static let maxDepth = 100

        /// When true, script arguments become runs at shifted levels; when false they are
        /// converted to Unicode super/subscript characters (or the `^(...)` fallback).
        var rich: Bool

        init(_ text: String, rich: Bool) {
            chars = Array(text)
            self.rich = rich
        }

        /// Remove leading/trailing ASCII spaces from a run list, dropping emptied runs.
        static func trimSpaces(_ runs: [MathRun]) -> [MathRun] {
            var result = runs
            while let first = result.first {
                let stripped = String(first.text.drop(while: { $0 == " " }))
                if stripped.isEmpty { result.removeFirst() } else { result[0].text = stripped; break }
            }
            while let last = result.last {
                var text = last.text
                while text.last == " " { text.removeLast() }
                if text.isEmpty { result.removeLast() } else { result[result.count - 1].text = text; break }
            }
            return result
        }

        /// Parse an argument and return its runs (italic flags kept). In rich mode the runs keep
        /// their script levels, so composite commands (`\frac`, `\sqrt`, fonts, environments)
        /// splice them into the output; in plain mode everything is at level 0.
        func parseFlatRuns(spaced: Bool) -> [MathRun] {
            return parseArgument(spaced: spaced)
        }

        /// True if the input at `pos` is `\\` or `\end` (a matrix cell/row/environment boundary).
        func atCellBoundary() -> Bool {
            guard pos + 1 < chars.count, chars[pos] == "\\" else { return false }
            if chars[pos + 1] == "\\" { return true }
            let end = Array("end")
            if pos + 3 < chars.count, Array(chars[(pos + 1)...(pos + 3)]) == end {
                let after = pos + 4
                return after >= chars.count || !(chars[after].isASCII && chars[after].isLetter)
            }
            return false
        }

        /// Parse atoms until end of input, a closing `}` (if `closeOnBrace`), one atom
        /// (if `singleAtom`) or a cell boundary `&`, `\\`, `\end` (if `cellMode`).
        func parseSequence(spaced: Bool, closeOnBrace: Bool, singleAtom: Bool, cellMode: Bool) -> [MathRun] {
            depth += 1
            defer { depth -= 1 }
            if depth > Parser.maxDepth {
                pos = chars.count
                return []
            }

            var b = Buffer(spaced: spaced)
            var atoms = 0

            while pos < chars.count {
                if singleAtom && atoms >= 1 { break }
                let c = chars[pos]

                if c.isWhitespace {
                    pos += 1
                    b.pending = true
                    continue
                }
                if c == "}" {
                    if singleAtom { break }
                    pos += 1
                    if closeOnBrace { break }
                    continue // stray closing brace: ignore
                }
                if cellMode && (c == "&" || atCellBoundary()) { break }
                atoms += 1

                switch c {
                case "{":
                    pos += 1
                    let inner = parseSequence(spaced: spaced, closeOnBrace: true, singleAtom: false, cellMode: false)
                    b.emitRuns(inner, .operand)
                case "^", "_":
                    pos += 1
                    b.pending = false
                    let argRuns = Parser.trimSpaces(parseArgument(spaced: false))
                    var argChars: [(ch: Character, italic: Bool)] = []
                    for run in argRuns { for ch in run.text { argChars.append((ch, run.italic)) } }
                    if c == "^" && argChars.count == 1 && argChars[0].ch == "∘" {
                        argChars = [("°", false)] // ^\circ is a degree sign
                    }
                    if argChars.isEmpty { continue }
                    if rich {
                        // Rich mode: keep the argument as runs shifted by one level.
                        // Primes and degree signs stay on the current level as Unicode.
                        if argChars.allSatisfy({ $0.ch == "′" || $0.ch == "°" }) {
                            b.append(String(argChars.map { $0.ch }))
                        } else {
                            let shift = (c == "^") ? 1 : -1
                            for run in argRuns { b.append(run.text, level: run.level + shift, italic: run.italic) }
                        }
                        b.prev = .operand
                        continue
                    }
                    // Plain mode: Unicode super/subscript characters; a mapped character
                    // keeps the italic value of its source character.
                    let table = (c == "^") ? LatexUnicode.superscripts : LatexUnicode.subscripts
                    var mapped: [(ch: Character, italic: Bool)] = []
                    for (ch, italic) in argChars {
                        let key: Character = (ch == "-") ? "−" : ch
                        guard let m = table[key] else { break }
                        mapped.append((m, italic))
                    }
                    if mapped.count == argChars.count {
                        for (ch, italic) in mapped { b.append(String(ch), italic: italic) }
                    } else {
                        b.append(String(c))
                        if argChars.count > 1 { b.append("(") }
                        for (ch, italic) in argChars { b.append(String(ch), italic: italic) }
                        if argChars.count > 1 { b.append(")") }
                    }
                    b.prev = .operand
                case "\\":
                    parseCommand(&b, spaced: spaced)
                case "&":
                    pos += 1
                    b.pending = true
                case "~":
                    pos += 1
                    b.pending = true
                case "-":
                    pos += 1
                    b.emitOperator("−", binary: b.prev == .operand)
                case "+":
                    pos += 1
                    b.emitOperator("+", binary: b.prev == .operand)
                case "=", "<", ">":
                    pos += 1
                    b.emitOperator(String(c), binary: true)
                case "'":
                    pos += 1
                    b.emit("′", .operand)
                case ")", "]":
                    pos += 1
                    b.pending = false // no space before a closing bracket
                    b.emit(String(c), .operand)
                case "(", "[", ",", ";":
                    pos += 1
                    b.emit(String(c), .open)
                default:
                    pos += 1
                    b.emit(String(c), .operand, italic: c.isASCII && c.isLetter)
                }
            }
            return Parser.trimSpaces(b.runs)
        }

        /// Parse one argument: a `{group}` or a single atom. Returns the converted text.
        func parseArgument(spaced: Bool) -> [MathRun] {
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            guard pos < chars.count else { return [] }
            if chars[pos] == "{" {
                pos += 1
                return parseSequence(spaced: spaced, closeOnBrace: true, singleAtom: false, cellMode: false)
            }
            return parseSequence(spaced: spaced, closeOnBrace: false, singleAtom: true, cellMode: false)
        }

        /// Read an argument verbatim (nested braces dropped, content and spaces kept).
        func parseRawArgument() -> String {
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            guard pos < chars.count else { return "" }
            if chars[pos] != "{" {
                let single = String(chars[pos])
                pos += 1
                return single
            }
            var level = 0
            var text = ""
            while pos < chars.count {
                let ch = chars[pos]
                pos += 1
                if ch == "{" { level += 1; continue }
                if ch == "}" {
                    level -= 1
                    if level <= 0 { break }
                    continue
                }
                text.append(ch)
            }
            return text
        }

        /// Handle a backslash command; `pos` is at the backslash on entry.
        func parseCommand(_ b: inout Buffer, spaced: Bool) {
            pos += 1
            guard pos < chars.count else { return }

            var name = ""
            if chars[pos].isASCII && chars[pos].isLetter {
                while pos < chars.count, chars[pos].isASCII, chars[pos].isLetter {
                    name.append(chars[pos])
                    pos += 1
                }
            } else {
                name = chars[pos].isWhitespace ? " " : String(chars[pos])
                pos += 1
            }

            // Spacing
            switch name {
            case ",", ";", ":", " ", "\\":
                b.pending = true
                return
            case "!":
                return
            case "quad":
                b.emit("\u{E000}\u{E000}", b.prev)
                return
            case "qquad":
                b.emit("\u{E000}\u{E000}\u{E000}\u{E000}", b.prev)
                return
            default:
                break
            }

            if LatexUnicode.sizingCommands.contains(name) {
                if pos < chars.count, chars[pos] == "." { pos += 1 } // \left. and \right. are empty
                return
            }
            if LatexUnicode.ignoredCommands.contains(name) { return }

            if let sym = LatexUnicode.symbols[name] {
                if name == "pm" || name == "mp" {
                    b.emitOperator(sym, binary: b.prev == .operand)
                } else if LatexUnicode.spacedSymbols.contains(sym) {
                    b.emitOperator(sym, binary: true)
                } else if LatexUnicode.prefixSymbols.contains(sym) {
                    b.emit(sym, .op)
                } else {
                    let italicGreek = sym.count == 1 && "αβγδεϵζηθϑικϰλμνξοπϖρϱσςτυφϕχψω".contains(sym)
                    b.emit(sym, sym == "{" ? .open : .operand, italic: italicGreek)
                }
                return
            }

            if LatexUnicode.functionNames.contains(name) {
                b.emit(name, .operand)
                // `\sin\theta` should read "sin θ"; `\sin(x)` and `\sin^2` stay tight.
                if pos < chars.count {
                    let next = chars[pos]
                    if next.isLetter || next.isNumber || next == "\\" || next == "{" { b.pending = true }
                }
                return
            }

            if LatexUnicode.rawTextCommands.contains(name) {
                b.emitText(parseRawArgument(), italicLetters: name == "textit")
                return
            }
            if LatexUnicode.plainFontCommands.contains(name) {
                for run in parseFlatRuns(spaced: spaced) {
                    b.emitText(run.text, italicLetters: name == "mathit", level: run.level)
                }
                return
            }
            if LatexUnicode.styledFontCommands.contains(name) {
                for run in parseFlatRuns(spaced: spaced) {
                    b.emitText(LatexUnicode.styled(run.text, font: name), italicLetters: false, level: run.level)
                }
                return
            }
            if let mark = LatexUnicode.accentMarks[name] {
                // The combining mark takes the italic value of its base character.
                var pieces: [(text: String, italic: Bool, level: Int)] = []
                for run in parseFlatRuns(spaced: spaced) {
                    for ch in run.text { pieces.append((String(ch), run.italic, run.level)) }
                }
                let everyChar = LatexUnicode.everyCharAccents.contains(name)
                for (i, piece) in pieces.enumerated() {
                    let marked = everyChar ? !piece.text.first!.isWhitespace : (i == pieces.count - 1)
                    b.emit(marked ? piece.text + mark : piece.text, .operand, level: piece.level, italic: piece.italic)
                }
                return
            }

            switch name {
            case "frac", "dfrac", "tfrac":
                let numerator = parseFlatRuns(spaced: spaced)
                let denominator = parseFlatRuns(spaced: spaced)
                let numText = numerator.map { $0.text }.joined()
                let denText = denominator.map { $0.text }.joined()
                if numText.count == 1, denText.count == 1,
                   let vulgar = LatexUnicode.vulgarFractions[numText + "/" + denText] {
                    b.emit(vulgar, .operand)
                } else {
                    let needsParens: (String) -> Bool = { text in
                        text.contains(where: { " +−-⋅×/".contains($0) })
                    }
                    if needsParens(numText) { b.emit("(", .operand) }
                    b.emitRuns(numerator, .operand)
                    if needsParens(numText) { b.emit(")", .operand) }
                    b.emit("/", .operand)
                    if needsParens(denText) { b.emit("(", .operand) }
                    b.emitRuns(denominator, .operand)
                    if needsParens(denText) { b.emit(")", .operand) }
                }
            case "binom":
                let n = parseFlatRuns(spaced: spaced)
                let k = parseFlatRuns(spaced: spaced)
                b.emit("C(", .operand)
                b.emitRuns(n, .operand)
                b.emit(",", .operand)
                b.emitRuns(k, .operand)
                b.emit(")", .operand)
            case "sqrt":
                while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
                var index: String? = nil
                if pos < chars.count, chars[pos] == "[" {
                    pos += 1
                    var text = ""
                    while pos < chars.count, chars[pos] != "]" {
                        text.append(chars[pos])
                        pos += 1
                    }
                    if pos < chars.count { pos += 1 }
                    index = text.trimmingCharacters(in: .whitespaces)
                }
                let body = parseFlatRuns(spaced: spaced)
                var radical = "√"
                if let n = index {
                    if n == "3" { radical = "∛" }
                    else if n == "4" { radical = "∜" }
                    else if n != "2" && !n.isEmpty {
                        radical = String(n.map { LatexUnicode.superscripts[$0] ?? $0 }) + "√"
                    }
                }
                let wrap = body.map { $0.text }.joined().count > 1
                b.emit(radical, .operand)
                if wrap { b.emit("(", .operand) }
                b.emitRuns(body, .operand)
                if wrap { b.emit(")", .operand) }
            case "begin":
                parseEnvironment(&b, spaced: spaced)
            case "end":
                _ = parseRawArgument() // stray \end
            default:
                b.emit(name, .operand) // unknown command: name without backslash
            }
        }

        /// Handle `\begin{name} ... \end{name}`; `pos` is just after `\begin`.
        /// Best effort: pmatrix `(a b; c d)`, bmatrix `[..]`, cases `{ a, b; c, d }`,
        /// anything else `[..]` with cells separated by spaces and rows by `; `.
        func parseEnvironment(_ b: inout Buffer, spaced: Bool) {
            let name = parseRawArgument().trimmingCharacters(in: .whitespaces)
            if name == "array" || name == "tabular" || name == "subarray" { _ = parseRawArgument() }

            var rows: [[[MathRun]]] = []
            var cells: [[MathRun]] = []
            var finished = false
            while !finished {
                let cell = parseSequence(spaced: true, closeOnBrace: false, singleAtom: false, cellMode: true)
                cells.append(cell)
                if pos >= chars.count {
                    finished = true
                } else if chars[pos] == "&" {
                    pos += 1
                } else if atCellBoundary(), chars[pos + 1] == "\\" {
                    pos += 2
                    rows.append(cells)
                    cells = []
                } else if atCellBoundary() {
                    pos += 4
                    _ = parseRawArgument()
                    finished = true
                } else {
                    pos += 1 // defensive: guarantee progress
                }
            }
            rows.append(cells)
            rows = rows.filter { row in row.contains(where: { !$0.isEmpty }) }

            let cellSeparator = (name == "cases") ? ", " : " "
            let delimiters: (open: String, close: String)
            switch name {
            case "pmatrix": delimiters = ("(", ")")
            case "Bmatrix": delimiters = ("{", "}")
            case "vmatrix": delimiters = ("|", "|")
            case "Vmatrix": delimiters = ("‖", "‖")
            case "cases": delimiters = ("{ ", " }")
            default: delimiters = ("[", "]")
            }
            b.emit(delimiters.open, .operand)
            for (r, row) in rows.enumerated() {
                if r > 0 { b.emit("; ", .operand) }
                for (c, cell) in row.enumerated() {
                    if c > 0 { b.emit(cellSeparator, .operand) }
                    b.emitRuns(cell, .operand)
                }
            }
            b.emit(delimiters.close, .operand)
        }
    }
}

extension LatexUnicode {
    /// Built-in examples used by the `selftest` executable. Each pair is (input, expectedOutput).
    public static let examples: [(String, String)] = [
        ("\\alpha^2 + \\beta_1", "α² + β₁"),
        ("E=mc^2", "E = mc²"),
        ("\\frac{a+b}{2}", "(a + b)/2"),
        ("\\frac{1}{2}", "½"),
        ("x_{i,j}", "x_(i,j)"),
        ("\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}", "∫₀^∞ e⁻ˣ² dx = √π/2"),
        ("\\nabla \\cdot \\vec{E} = \\rho/\\epsilon_0", "∇ ⋅ E\u{20D7} = ρ/ϵ₀"),
        ("\\mathbb{R}^n", "ℝⁿ"),
        ("\\hat{H}\\psi = E\\psi", "H\u{302}ψ = Eψ"),
        ("x \\in [0, 1]", "x ∈ [0, 1]"),
        ("\\sum_{n=0}^{N} a_n", "∑ₙ₌₀ᴺ aₙ"),
        ("f'(x)", "f′(x)"),
        ("\\text{if } x > 0", "if x > 0"),
        ("\\lambda_{\\max}", "λₘₐₓ"),
        ("", ""),
        ("\\", ""),
        ("{{{", ""),
        ("a+b=c", "a + b = c"),
        ("-x", "−x"),
        ("e^{-x^2}", "e⁻ˣ²"),
        ("x^\\prime + y^{\\prime\\prime}", "x′ + y′′"),
        ("\\theta^\\circ", "θ°"),
        ("\\sqrt{x+1}", "√(x + 1)"),
        ("\\sqrt[3]{x}", "∛x"),
        ("\\sqrt[5]{xy}", "⁵√(xy)"),
        ("\\mathcal{L} \\mathfrak{g} \\mathbf{v}", "ℒ 𝔤 𝐯"),
        ("\\bar{x} + \\underline{ab}", "x\u{305} + a\u{332}b\u{332}"),
        ("\\left( \\frac{a}{b} \\right)", "(a/b)"),
        ("\\left.x\\right|_0", "x|₀"),
        ("\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}", "(a b; c d)"),
        ("\\begin{cases}x & y\\\\z & w\\end{cases}", "{ x, y; z, w }"),
        ("\\sin\\theta + \\log(x)", "sin θ + log(x)"),
        ("\\lim_{x\\to 0} f", "lim_(x→0) f"),
        ("\\foo{bar", "foobar"),
        ("x_1^2", "x₁²"),
        ("a \\pm b, -c", "a ± b, −c"),
        ("\\frac{1}{x+1}", "1/(x + 1)"),
        ("a\\quad b", "a   b"),
        ("\\}\\}}}", "}}"),
    ]
}

extension LatexUnicode {
    /// Shorthand for building expected runs: `run(text, level, italic)`.
    private static func run(_ text: String, _ level: Int, _ italic: Bool) -> MathRun {
        MathRun(text: text, level: level, italic: italic)
    }

    /// Built-in examples for `convertRich(_:)` (scripts as shifted levels). Each pair is
    /// (input, expected runs). Spaces attach to the run before them (or to the run after
    /// them when the preceding run is at another level), whatever that run's italic value:
    /// `\sin\theta + 2x` gives "sin "↑up, "θ "↑it, "+ 2"↑up, "x"↑it.
    public static let richExamples: [(String, [MathRun])] = [
        ("x_b", [run("x", 0, true), run("b", -1, true)]),
        ("B_\\phi", [run("B", 0, true), run("ϕ", -1, true)]),
        ("x_{i,j}", [run("x", 0, true), run("i", -1, true), run(",", -1, false), run("j", -1, true)]),
        ("e^{-x^2}", [run("e", 0, true), run("−", 1, false), run("x", 1, true), run("2", 2, false)]),
        ("T_{\\mathrm{eff}}", [run("T", 0, true), run("eff", -1, false)]),
        ("x_{\\mathrm{max}}", [run("x", 0, true), run("max", -1, false)]),
        ("\\alpha^2 + \\beta_1",
         [run("α", 0, true), run("2", 1, false), run(" + ", 0, false), run("β", 0, true), run("1", -1, false)]),
        ("f'(x)", [run("f", 0, true), run("′(", 0, false), run("x", 0, true), run(")", 0, false)]),
        ("R^2_0", [run("R", 0, true), run("2", 1, false), run("0", -1, false)]),
        ("\\int_0^\\infty e^{-x^2}\\,dx",
         [run("∫", 0, false), run("0", -1, false), run("∞", 1, false), run(" e", 0, true),
          run("−", 1, false), run("x", 1, true), run("2", 2, false), run(" dx", 0, true)]),
        ("90^\\circ", [run("90°", 0, false)]),
        ("x_{i_j}", [run("x", 0, true), run("i", -1, true), run("j", -2, true)]),
        ("e^{\\frac{a}{b}}", [run("e", 0, true), run("a", 1, true), run("/", 1, false), run("b", 1, true)]),
        ("x^{a^b}", [run("x", 0, true), run("a", 1, true), run("b", 2, true)]),
        ("F^{\\prime\\prime}_n", [run("F", 0, true), run("′′", 0, false), run("n", -1, true)]),
        ("\\sin\\theta + 2x",
         [run("sin ", 0, false), run("θ ", 0, true), run("+ 2", 0, false), run("x", 0, true)]),
        ("\\Delta E = \\hbar\\omega",
         [run("Δ ", 0, false), run("E ", 0, true), run("= ℏ", 0, false), run("ω", 0, true)]),
        ("\\mathrm{d}x", [run("d", 0, false), run("x", 0, true)]),
        ("\\mathit{ab}", [run("ab", 0, true)]),
        ("e^{i\\pi}", [run("e", 0, true), run("iπ", 1, true)]),
        ("x^{2y}", [run("x", 0, true), run("2", 1, false), run("y", 1, true)]),
        ("\\hat{H}\\psi = E\\psi", [run("Ĥψ ", 0, true), run("= ", 0, false), run("Eψ", 0, true)]),
        ("\\text{if } x > 0", [run("if ", 0, false), run("x ", 0, true), run("> 0", 0, false)]),
        // Composite commands splice their arguments' runs (levels and italics kept).
        ("q = \\frac{r B_\\phi}{R B_\\theta}",
         [run("q ", 0, true), run("= (", 0, false), run("r B", 0, true), run("ϕ", -1, true),
          run(")/(", 0, false), run("R B", 0, true), run("θ", -1, true), run(")", 0, false)]),
        ("\\sqrt{x^2+y^2}",
         [run("√(", 0, false), run("x", 0, true), run("2", 1, false), run(" + ", 0, false),
          run("y", 0, true), run("2", 1, false), run(")", 0, false)]),
        ("\\frac{\\partial^2 u}{\\partial t^2}",
         [run("(∂", 0, false), run("2", 1, false), run(" u", 0, true), run(")/(∂ ", 0, false),
          run("t", 0, true), run("2", 1, false), run(")", 0, false)]),
        ("\\left( a_n \\right)", [run("(", 0, false), run("a", 0, true), run("n", -1, true), run(")", 0, false)]),
        ("\\mathrm{x_1}", [run("x", 0, false), run("1", -1, false)]),
        ("\\begin{pmatrix}a_1&b\\\\c&d^2\\end{pmatrix}",
         [run("(", 0, false), run("a", 0, true), run("1", -1, false), run(" b", 0, true), run("; ", 0, false),
          run("c d", 0, true), run("2", 1, false), run(")", 0, false)]),
        ("\\frac{1}{2}", [run("½", 0, false)]),
        ("", []),
    ]

    /// Built-in examples for `convertRich(_:unicodeScripts: true)`: all runs at level 0, the
    /// concatenated text equals `convert(_:)`, and a Unicode script character is italic when
    /// its source letter is (ᵢ from i), upright otherwise (² from 2, `_(`, `)`).
    public static let unicodeRichExamples: [(String, [MathRun])] = [
        ("x_b", [run("x", 0, true), run("_", 0, false), run("b", 0, true)]),
        ("B_\\phi", [run("B", 0, true), run("_", 0, false), run("ϕ", 0, true)]),
        ("x_i", [run("xᵢ", 0, true)]),
        ("x_1 + y^2", [run("x", 0, true), run("₁ + ", 0, false), run("y", 0, true), run("²", 0, false)]),
        ("x_{i,j}", [run("x", 0, true), run("_(", 0, false), run("i", 0, true), run(",", 0, false),
                     run("j", 0, true), run(")", 0, false)]),
        ("T_{\\mathrm{eff}}", [run("T", 0, true), run("_(eff)", 0, false)]),
        ("x^{2y}", [run("x", 0, true), run("²", 0, false), run("ʸ", 0, true)]),
        ("e^{i\\pi}", [run("e", 0, true), run("^(", 0, false), run("iπ", 0, true), run(")", 0, false)]),
        ("x^{a^b}", [run("xᵃᵇ", 0, true)]),
        ("R^2_0", [run("R", 0, true), run("²₀", 0, false)]),
        ("\\sin\\theta + 2x",
         [run("sin ", 0, false), run("θ ", 0, true), run("+ 2", 0, false), run("x", 0, true)]),
        ("\\alpha^2 + \\beta_1",
         [run("α", 0, true), run("² + ", 0, false), run("β", 0, true), run("₁", 0, false)]),
        ("90^\\circ", [run("90°", 0, false)]),
        ("", []),
    ]
}
