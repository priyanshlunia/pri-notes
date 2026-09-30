# Design notes: Pri Notes v1.1 (2026-09-30)

A menu-bar app (LSUIElement) that adds Markdown, LaTeX math and a selection formatting toolbar to Apple
Notes. It watches typing and drives Notes through the Accessibility (AX) API. It is fully
offline and builds with the Xcode Command Line Tools alone.
For a guided walkthrough with diagrams, see [learnings.md](learnings.md).

## How it works

**Detection.** A CGEventTap runs while Notes is frontmost.
- It is pass-through, except that it swallows ⌃⌘E (equation toggle) and ⌘U (reliable underline).
- 20 ms after a trigger character (`space * _ ~ $ \``) it reads the focused `AXTextArea`'s text and
  selection. `Rules.detect` then checks whether the text ending at the cursor completes a pattern.
- Detection is stateless and line-local.
- Markdown openers inside `$…`/`$$…` spans (`MathSpans`) are ignored, and nothing converts inside
  monostyled paragraphs.

**The four ways the app changes Notes** (each verified in Notes):

| Technique | Used for |
|---|---|
| AX: set `AXSelectedTextRange`, then `AXSelectedText` (undoable) | removing Markdown markers, inserting equation and code text, retyping to remove underline |
| AX-press a Format-menu item by title (English UI) | Title/Heading/…/Checklist, Bold/Italic/Underline **on**, Strikethrough, Bigger/Smaller, Baseline ▸ Superscript/Subscript |
| **Paste Style**: a one-character RTF sample (`StyleSample.rtf`) on the *font* pasteboard, then Format ▸ Font ▸ Paste Style | fonts (Palatino, Menlo, toolbar family and typeface), exact sizes, colours, Bold/Italic on and off |
| General clipboard + Edit ▸ Paste (restored after 0.5 s) | links, equation images |

`SelectionStyler.pasteStyles` applies styles run by run:
- It waits until each run shows its new style, because Notes reads the font pasteboard after the menu
  press returns.
- It restores the user's font pasteboard afterwards.
- Where a colour must be kept, it reads the *stored* colour first with Copy Style.

**Text math (`$…$`).**
- `LatexUnicode.convertRich` produces `MathRun`s (text, script level, italic).
- The source is replaced through AX with the plain text plus U+200B. The inserted text inherits the
  typed text's colour and size, and the U+200B keeps the user's font for later typing.
- Script runs get Notes' Superscript/Subscript first; that also shrinks them by about 0.83×.
- Then every run gets Palatino Italic or Roman at the exact size with Paste Style. Scripts are at 70 %
  (50 % deeper, as in TeX), and the sample carries the script direction.
- An optional mode uses Unicode script characters instead.

**Equation images (`$$…$$`).**
- MathJax 3.2.2 runs in a hidden, locked-down WKWebView: TeX → SVG → canvas → PNG at 2×.
- The background is transparent, and the ink is black or white for the appearance at insert time.
- The LaTeX is embedded in the PNG metadata, and the PNG is pasted over the source.
- Bad LaTeX keeps the source, beeps, and shows the error in the menu.

**Live preview and re-editing.**
- The glass preview panel renders the `$…`/`$$…` span under the cursor.
- ⌃⌘E inside a span converts it now. After an equation, it reopens it as `$source` / `$$source`.
- Image sources are recovered from the attachment inside `com.apple.flat-rtfd` after Edit ▸ Copy.
  Notes fills that lazily, so the app retries for up to 1.5 s.
- Text equations are found through `EquationStore`: `equations.json`, capped at 5,000 entries.

**Selection toolbar.**
- A never-key, non-activating `NSPanel` with four `NSGlassEffectView` capsules, laid out by hand.
- Controls accept the first click, so focus stays in Notes. It appears 0.3 s after a key or click that
  leaves a selection, and isn't rebuilt while its menus are open.
- It reads style runs from `AXAttributedStringForRange`.
- Font, typeface and B/I skip equations (a Palatino stretch followed by U+200B). Colour, size and U/S
  apply to them.

## Notes behaviours worth knowing

- **Menu items:** they are disabled whenever Notes isn't frontmost, so the styler re-activates Notes
  first (needed after the colour panel).
- **Paste and Retain Style:** its enabled state follows a stale view of the clipboard, so pressing it
  right after writing the clipboard is silently ignored. That's why the app doesn't use it.
- **Paste Style:** applies family, size, colour and script direction, and keeps underline and
  strikethrough.
  - A sample with no colour resets the text to the automatic colour.
  - A sample can't *remove* underline: RTF `\ulnone` reads back as absent.
- **RTF:** AppKit's writer turns the system font into Helvetica Neue, so samples are hand-written with
  AppKit's own names (`.AppleSystemUIFont`, `.SFNS-RegularItalic`, …). A plain RTF colour table reads
  back as Generic RGB (0.45 → 0.54), so samples use `\expandedcolortbl` with `\cssrgb`.
- **Dark mode:** Notes *draws* explicit colours lighter than it stores them, and AX reports the drawn
  colour. Writing that back drifts paler with every edit. The stored colour comes from Copy Style.
- **Toggles:** driven by AX, Bold, Italic and Underline only *add* (Underline doesn't switch off from ⌘U
  either); Strikethrough works both ways. So:
  - B/I are applied as fonts;
  - U off retypes each run in place, then restores font, stored colour, size, script direction and
    strikethrough (links are skipped);
  - ⌘U is routed to the same toggle.
- **The system font:** Notes stores it as bold/italic only, so Semibold becomes Bold. The typeface
  menu offers only Regular, Italic, Bold and Bold Italic.
- **Remove Style:** resets the whole paragraph, so it isn't used.

## Privacy, resources and identity

- **Offline:** the Swift code has no networking APIs. The MathJax WebView is locked down by a
  content-rule list (only `file:`/`data:`), a CSP (`connect-src 'none'`), a file-only navigation
  policy, a disabled MathJax menu and a non-persistent data store. `--network-test` shows every
  request blocked while `curl` gets through (control). `lsof` shows no sockets.
- **Sandbox:** impossible, because sandboxed apps can't drive other apps through Accessibility.
- **Resources:** about 80 MB for the app plus about 95 MB for WebKit helpers, and ~0 % CPU when idle. A
  0.6 % reading in `top` is AppKit answering *other* tools' Accessibility queries about the menu-bar
  item.
- **Identity:** the bundle id is `local.prinotes`. The app is signed with a self-signed "Pri Notes
  Local Signing" certificate, so the Accessibility grant survives rebuilds.
- **Old name:** the app was first called Notes Markdown. Two pieces of compatibility remain:
  - equation images tagged `notesmarkdown-latex:` are still recognised for ⌃⌘E;
  - an old `Application Support/NotesMarkdown` history folder is moved to `PriNotes` on first
    launch.
- **Icons:** `scripts/make_icon.swift` draws the dark-mode Notes pad with an italic Palatino "P" (the
  system `.icns` stops at 256 px). `MenuBarIcon.swift` draws the menu-bar template icon.
- **MathJax, not TeX:** a TeX install is large, optional and not on most Macs. The bundled MathJax
  runs offline on any Mac with nothing extra installed.

## Verification

- **Self-tests:** `swift run selftest` passes 178/178. It covers rules, math spans, LaTeX examples,
  rich and Unicode runs, style-sample RTF round trips (exact sRGB), and script sizes.
- **In Notes:** `--notes-lab` in a note starting "PRI-LAB":
  - `--phase3`: every toolbar change;
  - `--phase4`: equations after styled text, Palatino kept, colour matched exactly;
  - `--phase7`: B/I/U/S on and off with font and colour kept.
- **Offline checks:** `--render`, `--preview-snapshot`, `--toolbar-snapshot`, `--menubar-icon`,
  `--network-test`, `--recover-from-clipboard`.
- **Confirmed in use:** Markdown, text math, image re-editing, the glass toolbar and preview, and U/⌘U
  on and off.
- **Not yet confirmed:**
  - doubly nested scripts (`x^{a^b}`);
  - an image equation after the appearance changes.
  - whether typing right after a `**bold**` conversion continues in bold. The conversion presses Bold
    again to switch the typing style off, and Bold only switches on when driven this way.

## Known limitations

- Equation images keep the ink colour of the appearance they were inserted in; ⌃⌘E twice re-renders.
- Without a selection, ⌃⌘E reopens only the most recent text equation.
- Toolbar changes and underline removal take several ⌘Z steps to undo, one per style run.
- Underlined links keep their underline. Text right after an underlined character re-inherits the
  underline when it is retyped.
- Menu titles are matched in English.
