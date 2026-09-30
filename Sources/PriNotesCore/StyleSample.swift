import AppKit

/// Character style carried by one run of text: the pieces the selection toolbar can change.
public struct CharacterStyle {
    public var font: NSFont
    /// nil means "automatic" (Notes' normal text colour, which adapts to dark mode).
    public var color: NSColor?
    /// +1 superscript, −1 subscript, 0 baseline.
    public var baseline: Int

    public init(font: NSFont, color: NSColor? = nil, baseline: Int = 0) {
        self.font = font
        self.color = color
        self.baseline = baseline
    }
}

/// Builds the one-character "style sample" that Notes' Format ▸ Font ▸ Paste Style applies to the
/// selection, and the font conversions the selection toolbar needs.
///
/// Why hand-written RTF: the style sample travels on the font pasteboard as RTF. AppKit's RTF writer
/// replaces the macOS system font with Helvetica Neue (RTF has no name for it), so applying a size or
/// colour to system-font text would silently change its font. Writing the RTF by hand with AppKit's
/// own font names (`.AppleSystemUIFont`, `.AppleSystemUIFontBold`, `.SFNS-RegularItalic`, …) keeps it.
/// Verified in Notes with the `--notes-lab` experiments (see docs/NOTES.md).
///
/// Example:
/// ```swift
/// let style = CharacterStyle(font: NSFont.systemFont(ofSize: 22), color: .systemRed)
/// let rtf = StyleSample.rtf(style)   // put on NSPasteboard(name: .font), then press Paste Style
/// ```
public enum StyleSample {

    /// RTF for a single "x" carrying `style`.
    public static func rtf(_ style: CharacterStyle) -> Data {
        let font = normalized(style.font)
        var rtf = "{\\rtf1\\ansi\\ansicpg1252{\\fonttbl\\f0\\fnil \(escaped(font.fontName));}"
        if let color = style.color?.usingColorSpace(.sRGB) {
            // The plain colour table alone is read back as *Generic RGB*, which shifts every colour
            // (sRGB 1.00,0.45,0.41 → 1.00,0.54,0.49); the expanded table pins it to sRGB, as AppKit does.
            func clamp(_ c: CGFloat) -> CGFloat { min(max(c, 0), 1) }
            func byte(_ c: CGFloat) -> Int { Int((clamp(c) * 255).rounded()) }
            func milli(_ c: CGFloat) -> Int { Int((clamp(c) * 100000).rounded()) }
            rtf += "{\\colortbl;\\red\(byte(color.redComponent))\\green\(byte(color.greenComponent))\\blue\(byte(color.blueComponent));}"
            rtf += "{\\*\\expandedcolortbl;\\cssrgb\\c\(milli(color.redComponent))\\c\(milli(color.greenComponent))\\c\(milli(color.blueComponent));}"
        }
        rtf += "\\f0\\fs\(Int((font.pointSize * 2).rounded()))"
        if style.color != nil { rtf += "\\cf1" }
        if style.baseline > 0 { rtf += "\\super" } else if style.baseline < 0 { rtf += "\\sub" }
        rtf += " x}"
        return Data(rtf.utf8)
    }

    /// True for the macOS system font (SF), whatever face.
    public static func isSystem(_ font: NSFont) -> Bool {
        let family = font.familyName ?? ""
        return family.hasPrefix(".") || font.fontName.hasPrefix(".")
    }

    /// Rebuild system fonts through `NSFont.systemFont(ofSize:weight:)` so their names are ones
    /// that round-trip through RTF; other fonts are returned unchanged.
    public static func normalized(_ font: NSFont) -> NSFont {
        guard isSystem(font) else { return font }
        let traits = NSFontManager.shared.traits(of: font)
        return systemFace(weight: systemWeight(of: font), italic: traits.contains(.italicFontMask), size: font.pointSize)
    }

    /// The system font at a given weight, optionally italic.
    public static func systemFace(weight: NSFont.Weight, italic: Bool, size: CGFloat) -> NSFont {
        let upright = NSFont.systemFont(ofSize: size, weight: weight)
        return italic ? NSFontManager.shared.convert(upright, toHaveTrait: .italicFontMask) : upright
    }

    /// Weights offered in the typeface menu for the system font. Notes stores the system font as
    /// bold/italic only: other weights (Light, Semibold, …) are saved as Regular or Bold (verified
    /// with `--notes-lab --phase3`), so only these two are offered.
    public static let systemWeights: [(name: String, weight: NSFont.Weight)] = [("Regular", .regular), ("Bold", .bold)]

    /// Map NSFontManager's 0–15 weight scale onto the system weights above (semibold and heavier
    /// count as bold, as Notes treats them).
    public static func systemWeight(of font: NSFont) -> NSFont.Weight {
        NSFontManager.shared.weight(of: font) >= 8 ? .bold : .regular
    }

    /// Same size, weight and italic, in another family. `family == systemFamilyLabel` means the
    /// system font. Falls back to the family's regular face if the traits don't exist in it.
    public static func convert(_ font: NSFont, toFamily family: String) -> NSFont {
        let fm = NSFontManager.shared
        let traits = fm.traits(of: font)
        let italic = traits.contains(.italicFontMask)
        if family == systemFamilyLabel {
            let weight = isSystem(font) ? systemWeight(of: font)
                : (traits.contains(.boldFontMask) ? .bold : .regular)
            return systemFace(weight: weight, italic: italic, size: font.pointSize)
        }
        let source = isSystem(font) ? NSFont(name: "Helvetica Neue", size: font.pointSize) ?? font : font
        var converted = fm.convert(source, toFamily: family)
        if converted.familyName != family, let plain = NSFont(name: family, size: font.pointSize) {
            converted = plain   // e.g. the family's name is also its regular face's name
        }
        if traits.contains(.boldFontMask) { converted = fm.convert(converted, toHaveTrait: .boldFontMask) }
        if italic { converted = fm.convert(converted, toHaveTrait: .italicFontMask) }
        return converted.familyName == family ? converted : (fm.font(withFamily: family, traits: [], weight: 5, size: font.pointSize) ?? font)
    }

    /// Font size of a superscript/subscript at nesting `level` (±1, ±2, …) for text of size `base`,
    /// following TeX: first-level scripts at 70 % (\scriptstyle, 7 pt on 10 pt), deeper ones at
    /// 50 % (\scriptscriptstyle, 5 pt on 10 pt). Level 0 is the base size.
    ///
    /// Example: `StyleSample.scriptSize(base: 13, level: -1)` → 9.1
    public static func scriptSize(base: CGFloat, level: Int) -> CGFloat {
        switch abs(level) {
        case 0: return base
        case 1: return base * 0.7
        default: return base * 0.5
        }
    }

    /// Label used for the system font in the UI and in `convert(_:toFamily:)`.
    public static let systemFamilyLabel = "System"

    /// Display name of a font's family ("System" for SF).
    public static func familyLabel(of font: NSFont) -> String {
        isSystem(font) ? systemFamilyLabel : (font.familyName ?? font.fontName)
    }

    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: ";", with: "")
    }
}
