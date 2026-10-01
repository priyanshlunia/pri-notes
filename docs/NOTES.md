# Design notes: Pri Notes v1.1 + iCloud file links (2026-10-01)

A menu-bar app (LSUIElement) that adds Markdown, LaTeX math and a selection formatting toolbar to Apple
Notes. It watches typing and drives Notes through the Accessibility (AX) API. It is fully
offline and builds with the Xcode Command Line Tools alone.
For a guided walkthrough with diagrams, see [learnings.md](learnings.md).

## How it works

**Detection.** A CGEventTap runs while Notes is frontmost.
- It is pass-through, except that it swallows ⌃⌘E (equation toggle), ⌃⌘K (file link) and ⌘U
  (reliable underline).
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
| General clipboard + Edit ▸ Paste (restored after 0.5 s) | links (Markdown and file links, via `Formatter.pasteLink`), equation images |

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
- An unclosed span would run to the end of the line. `Formatter.editingSpan` remembers the text that
  followed the cursor when the edit began (after a reopen: the text after the equation) and keeps it
  outside the span (`MathSpans.trimmed`), so mid-sentence edits preview and convert only the equation.
- A text equation is recognised by its trailing U+200B. With the marker next to the cursor, any history
  entry may match (longest wins); without it, only the latest, so short results like "x" aren't
  confused with ordinary text. U+200B is stripped from every source before converting.
- Image sources are recovered from the attachment inside `com.apple.flat-rtfd` after Edit ▸ Copy.
  Notes fills that lazily, so the app retries for up to 1.5 s.
- Text equations are found through `EquationStore`: `equations.json`, capped at 5,000 entries.

**Selection toolbar.**
- A never-key, non-activating `NSPanel` with five `NSGlassEffectView` capsules, laid out by hand.
- Controls accept the first click, so focus stays in Notes. It appears 0.3 s after a key or click that
  leaves a selection, and isn't rebuilt while its menus are open.
- It reads style runs from `AXAttributedStringForRange`.
- Font, typeface and B/I skip equations (a Palatino stretch followed by U+200B). Colour, size and U/S
  apply to them.
- A fifth capsule holds the 🔗 file-link button, which hides the toolbar and runs `FileLinkInserter`.

**iCloud Drive file links (`shareddocuments://`).**
- Links hold the item's **iPhone** path, percent-encoded:
  `shareddocuments:///private/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/<path>`.
  The iPhone's Files app owns the scheme. `Mobile Documents` has the same layout on the Mac
  (`~/Library/Mobile Documents`), so `FileLinks` (core, selftested) maps one path to the other.
- macOS had no handler for the scheme, so `CFBundleURLTypes` in `build_app.sh` registers Pri Notes.
  Clicks arrive at `application(_:open:)`, which calls `FileLinkOpener`.
  - It opens folders in Finder and documents in their default app.
  - It only reveals apps, scripts, executables and location files: shared notes can carry links.
  - `FileLinks.macPath` refuses `..`, the host form, and anything outside `Mobile Documents`.
  - A missing target gets an alert. Renames and moves break links; the user accepted that.
- Inserting (`FileLinkInserter`, ⌃⌘K or 🔗):
  1. Save the context.
  2. Show an `NSOpenPanel` that starts in iCloud Drive. It alerts while still frontmost if the item
     is outside `Mobile Documents`.
  3. `styler.ensureNotesFrontmost()`.
  4. Paste only if the note's text is unchanged.

  A selection becomes the link with no trailing space. Otherwise the display name is inserted plus a
  plain space.
- Rejected alternatives: Shortcuts links (a shortcut per device, a visible app hop), iCloud share
  links (network, server-side sharing), `file://` and bookmarks (Mac only).

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
- **`shareddocuments://` links:** Notes keeps them clickable on the Mac and after syncing to the iPhone,
  and the Mac hands clicks to LaunchServices. On iPhone they open folders and files, including
  percent-encoded spaces and accents, `/var/…` without `/private`, and app containers. `file://` does
  nothing on iPhone. (Verified by hand, 2026-10-01.)
- **Text and selection can disagree:** they are separate AX reads, and while Notes switches notes the
  selection can run past the text (seen: {1008, 4} against 873 units). `currentContext()` rejects the
  pair; slicing would raise an uncatchable exception (this crashed the app on 2026-10-01).

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

- **Self-tests:** `swift run selftest` passes 196/196. It covers rules, math spans, LaTeX examples,
  rich and Unicode runs, style-sample RTF round trips (exact sRGB), script sizes, and file-link
  mapping and its safety checks.
- **In Notes:** `--notes-lab` in a note starting "PRI-LAB":
  - `--phase3`: every toolbar change;
  - `--phase4`: equations after styled text, Palatino kept, colour matched exactly;
  - `--phase7`: B/I/U/S on and off with font and colour kept;
  - `--phase8`: ⌃⌘E reopening any text equation mid-sentence, the edited span stopping at the rest
    of the sentence, and no U+200B in stored sources.
- **Offline checks:** `--render`, `--preview-snapshot`, `--toolbar-snapshot`, `--menubar-icon`,
  `--network-test`, `--recover-from-clipboard`.
- **Confirmed in use:** Markdown, text math, image re-editing, the glass toolbar and preview, and U/⌘U
  on and off. File links (2026-10-01): inserting at the cursor and over a selection, cancel,
  the outside-iCloud alert, typing after a link, and clicks on Mac (also with the app not running)
  and iPhone.
- **Not yet confirmed:**
  - doubly nested scripts (`x^{a^b}`);
  - an image equation after the appearance changes.
  - whether typing right after a `**bold**` conversion continues in bold. The conversion presses Bold
    again to switch the typing style off, and Bold only switches on when driven this way.

## Known limitations

- Equation images keep the ink colour of the appearance they were inserted in; ⌃⌘E twice re-renders.
- Toolbar changes and underline removal take several ⌘Z steps to undo, one per style run.
- Underlined links keep their underline. Text right after an underlined character re-inherits the
  underline when it is retyped.
- Menu titles are matched in English.
- File links break when the item is renamed or moved. Only items in iCloud folders can be linked.
