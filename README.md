# Pri Notes (v1.1)

A small menu-bar app that makes Apple Notes respond to Markdown as you type, adds LaTeX math, and
puts a Liquid Glass formatting toolbar above selected text. Fully offline. Modelled on the Markdown part of [NotesCmdr](https://smallest.app/notescmdr/).

## What it does

| You type (at line start)  | Notes gets                     |
|---------------------------|--------------------------------|
| `# ` / `## ` / `### `     | Title / Heading / Subheading   |
| ```` ``` ````             | Monostyled block               |
| `[] ` or `[ ] `           | Checklist                      |
| `> `                      | Block quote                    |
| `* `, `- `, `1. `         | Lists (Notes does this itself) |

| You type (anywhere)       | Notes gets                                        |
|---------------------------|---------------------------------------------------|
| `**bold**`                | **bold**                                          |
| `*italic*` or `_italic_`  | *italic*                                          |
| `__underline__`           | underline                                         |
| `~~strike~~`              | ~~strike~~                                        |
| `` `code` `` + space      | monospaced text                                   |
| `[text](url)` + space     | a link                                            |
| `$B_\phi^2 + x_1$`        | math as text, with real superscripts/subscripts   |
| `$$\frac{a}{b}$$`         | a typeset equation image (MathJax, fully offline) |

Conversions happen the moment the closing marker is typed (code and links: on the following
space). **⌘Z** undoes a conversion. Nothing is converted inside monostyled paragraphs.

LaTeX that fails to parse (e.g. `$$\frac{a}{$$`) is left as text; the app beeps and shows the error
in its menu. `$$…$$` supports AMS math plus `physics`, `braket`, `mathtools`, `cancel`, `color`.

## Equations

- **Live preview:** while the cursor is inside an unfinished `$…` or `$$…`, a floating panel shows the
  rendered equation (or the LaTeX error). Typing the closing `$`/`$$` inserts it.
- **Re-editing:** put the cursor right after an equation (or select it) and press **⌃⌘E**. It turns
  back into `$source` / `$$source` with the preview showing; edit, then type the closing delimiter
  (or press ⌃⌘E again) to convert it. Sources are kept in
  `~/Library/Application Support/PriNotes/equations.json`; image equations also carry their
  LaTeX in the PNG metadata. For a text equation without a selection, only the most recent one can be
  reopened this way; select older ones first.
- **Dark mode:** equation images have a transparent background and are drawn in white or black to
  match the appearance *at the time they are inserted*. After switching appearance, ⌃⌘E twice
  re-renders one in the new colour.
- **Text math style:** `$…$` is set in Palatino, with variables (Latin letters, lowercase Greek) in italic and
  `\mathrm`, `\text`, `\operatorname`, function names (`\sin`), digits, operators and uppercase Greek upright.
  Scripts use Notes' own Format ▸ Font ▸ Baseline ▸ Superscript/Subscript, so any letter can be a script
  (`B_\phi`, `T_{\mathrm{eff}}`). Turn off "Real superscripts/subscripts" in the menu to get Unicode
  characters (`x²`, `x₁`) instead, which survive copy-paste as plain text. An invisible zero-width space
  follows each equation so the text you type next is in your normal font.
  Superscripts and subscripts are set smaller, as in TeX: 70 % of the text size, and 50 % for scripts
  of scripts.

## Selection toolbar

Select text in a note and, after a short pause, a Liquid Glass toolbar appears above it:

`[ Font ▾ | Typeface ▾ ]  [ B  I  U  S ]  [ −  size ▾  + ]  [ colour ▾ ]`

- **Font:** a curated list (System, Palatino, Helvetica Neue, Avenir Next, Georgia, Times New Roman,
  Baskerville, Menlo, SF Mono), plus **All Fonts**. Each word keeps its own bold/italic and size.
- **Typeface:** the family's faces (e.g. Avenir Next's weights). For the system font, only Regular,
  Italic, Bold and Bold Italic, because Notes stores the system font as bold/italic only.
- **B / I / U / S:** switch the style on or off for the whole selection. If it all has the style, it's
  removed; otherwise it's added. Notes' own Bold/Italic/Underline commands can only add these styles
  when driven this way, so the app applies them itself. **⌘U** in Notes goes through the same toggle,
  because Notes' own ⌘U can't remove an underline. Removing an underline retypes the text in place
  and restores its font and colour; underlined links are left as they are.
- **Size:** − and + step 1 pt (Notes' Smaller/Bigger); the menu sets an exact size.
- **Colour:** Automatic (normal text colour, adapts to dark mode), seven system colours, or **More…**
  for the colour panel. The pick is applied when the panel closes.
- **Equations stay Palatino:** font, typeface, bold and italic changes skip `$…$` equations. Colour
  and size apply to them, so they match the surrounding text. New equations also take the colour
  and size of the text you type them into.

It hides when the selection is cleared, when you press Esc, or when Notes goes to the background.
Turn it off with "Selection toolbar" in the menu-bar menu. Changes use Notes' own commands
(Format ▸ Font ▸ Paste Style and friends), and only removing an underline retypes text. Links and
attachments are never touched. A change may take several ⌘Z presses to undo, one per style run.

## Privacy and resource use

Pri Notes is fully offline and keeps everything on this Mac.

- **No network code.** The Swift code uses no networking APIs. The only web component, the hidden
  WebKit view that runs MathJax, is locked down three ways: a WebKit content-blocker that refuses every
  non-`file:`/`data:` request, a Content-Security-Policy (`connect-src 'none'`, no remote scripts/images/fonts),
  and a navigation policy that only allows local files. MathJax's context menu (its only route to a
  CDN add-on) is disabled. Check with `.build/debug/PriNotes --network-test`: every fetch/image/script
  attempt must print "blocked".
- **What is stored:** `~/Library/Application Support/PriNotes/equations.json` (LaTeX source of each
  converted equation, for ⌃⌘E re-editing), preferences (`defaults read local.prinotes`), an
  error log at `~/Library/Logs/PriNotes.log` (only created when something fails; no note text), and
  WebKit's compiled block list. WebKit uses a non-persistent data store, so no caches or cookies.
- **What it sees:** macOS delivers every keystroke to the key tap, but it returns immediately unless Notes
  is frontmost, and nothing is recorded. While Notes is frontmost it reads the current note's text through
  Accessibility (in memory only) to find Markdown/math patterns. The clipboard is used only to insert
  links and equation images, and it is restored 0.5 s later. Fonts and colours go through the separate
  font pasteboard, which is also restored.
- **Cost:** ~0% CPU when idle (measured; the event tap does no work outside Notes). Memory ≈ 80 MB for the
  app plus ≈ 95 MB for WebKit's helper processes (MathJax).
- It can't use the App Sandbox (which would forbid networking at the OS level) because sandboxed apps may
  not control other apps via Accessibility. For an OS-level guarantee, use an outbound firewall such as
  LuLu or Little Snitch and deny "Pri Notes".

## Install

### Requirements

- **macOS 26 or later** (the toolbar uses Liquid Glass). Apple silicon or Intel; it's built from
  source for whichever Mac you're on.
- **The Xcode Command Line Tools**, for `swift`. Full Xcode isn't needed. Install them with
  `xcode-select --install`.
- **Notes in English.** The app finds Notes' Format-menu commands by their English titles, so other
  UI languages won't work yet.

### 1. Create a signing certificate (once per Mac)

macOS attaches the Accessibility permission to the app's signature. With a stable self-signed
certificate, the permission survives every rebuild. Without one, the app is signed ad-hoc, and you
have to grant Accessibility again after each build.

1. Open **Keychain Access** (search for it with Spotlight, since it's no longer in Utilities), then
   choose **Keychain Access ▸ Certificate Assistant ▸ Create a
   Certificate…**.
2. Enter the name **`Pri Notes Local Signing`** exactly, set **Identity Type** to *Self Signed
   Root* and **Certificate Type** to *Code Signing*, and click **Create**.
3. Check it's there:

   ```bash
   security find-identity -p codesigning
   ```

   It's listed with `CSSMERR_TP_NOT_TRUSTED`. That's expected for a self-signed certificate, and
   `codesign` still uses it. You don't need to change its trust settings.

The build script uses this certificate automatically. To sign with a different identity, set
`SIGN_IDENTITY="<name>"` when running the script. The first build after creating the certificate
may show a keychain prompt asking whether `codesign` can use the key; choose **Always Allow**.

### 2. Build and install

From the project folder:

```bash
scripts/build_app.sh
```

The script does five steps:
1. It compiles a release build with Swift Package Manager.
2. It assembles `Pri Notes.app`: the executable, `Resources/mathjax`, `Resources/AppIcon.icns` and a generated
   `Info.plist`.
3. It signs the app.
4. It installs it to `~/Applications/Pri Notes.app`, replacing any running copy.
5. It launches it.

Re-run it after any source change.

### 3. Grant Accessibility

On first launch, macOS asks for Accessibility access. Turn on **Pri Notes** in **System Settings →
Privacy & Security → Accessibility**. The app starts working within a couple of seconds, with no
relaunch needed.

The menu-bar icon (text lines with a "P" badge) has toggles for each feature, live preview, script
style, display-style images, and "Launch at Login".

### Uninstall

1. Quit Pri Notes from its menu.
2. Delete `~/Applications/Pri Notes.app`.
3. Remove it from the Accessibility list.
4. Optionally, delete:
   - `~/Library/Application Support/PriNotes/`;
   - `~/Library/Logs/PriNotes.log`;
   - the preferences, with `defaults delete local.prinotes`.

## Development

Run the self-tests:

```bash
swift run selftest
```

Build the debug executable (needed for the tools below):

```bash
swift build
```

Debug modes of that build. None of them touch Notes:

- `.build/debug/PriNotes --render '<latex>' out.png [pt] [--dark]` renders one equation, and
  prints the source read back from the PNG metadata and its pixel hash.
- `.build/debug/PriNotes --preview-snapshot '<latex>' out.png [--dark]` draws the live-preview
  panel to a PNG.
- `.build/debug/PriNotes --menubar-icon out.png [pt]` draws the menu-bar icon.
- `.build/debug/PriNotes --network-test` checks that the renderer can't reach the network.
- `.build/debug/PriNotes --recover-from-clipboard`: after copying an equation image in Notes, runs the
  ⌃⌘E recovery code on the clipboard and prints the LaTeX it finds.
- `.build/debug/PriNotes --toolbar-snapshot out.png [--dark]` draws the selection toolbar's controls.

In-Notes regression tests. These run in the focused note, only if it starts with "PRI-LAB", and they
rewrite that note. Keep Notes in front and hands off while they run.

```bash
open -n ~/Applications/Pri\ Notes.app --args --notes-lab /tmp/lab.txt --phase3
```

- `--phase3`: toolbar changes.
- `--phase4`: equations after styled text, and colour matching.
- `--phase7`: B/I/U/S on and off.

Read the report in `/tmp/lab.txt` afterwards.

The app icon is drawn by `scripts/make_icon.swift`, a dark-mode Notes-style pad with an italic Palatino
"P". Regenerate it, then rerun `scripts/build_app.sh`:

```bash
swiftc -O -o /tmp/make_icon scripts/make_icon.swift && /tmp/make_icon Resources/AppIcon.icns
```

Layout:

- `Sources/PriNotesCore/`: pure logic, covered by `selftest`.
  - `Rules.swift`: which Markdown or math pattern ends at the cursor.
  - `MathSpans.swift`: finds `$…$` and `$$…$$` spans on a line, for the preview and the in-math guard.
  - `LatexUnicode.swift`: LaTeX to text, as `MathRun`s with script level and italic flag.
  - `StyleSample.swift`: the RTF style sample for Paste Style (keeps the system font) and font conversions.
- `Sources/PriNotes/`: the app.
  - `main.swift`: app delegate, menu, settings, debug modes.
  - `KeyMonitor.swift`: global key and click tap, active only while Notes is frontmost; ⌃⌘E and ⌘U.
  - `SelectionToolbar.swift`, `SelectionStyler.swift`: the Liquid Glass toolbar, and reading and
    applying styles (Paste Style, toggles, underline removal).
  - `NotesAX.swift`: Accessibility access to Notes (text, selection, fonts, bounds, menu items).
  - `Formatter.swift`: applies each action to the note, and handles ⌃⌘E re-editing.
  - `MathRenderer.swift`: locked-down, offline MathJax WebView, TeX to PNG.
  - `PreviewPanel.swift`: the live equation preview panel.
  - `EquationStore.swift`: equation history used for re-editing.
  - `MenuBarIcon.swift`: the menu-bar icon.
  - `Lab.swift`: the `--notes-lab` in-Notes experiment and regression harness.
  - `Log.swift`: the error log.
- `Sources/selftest/main.swift`: assertion tests (XCTest isn't available with the Command Line Tools
  alone).
- `Resources/mathjax/`: MathJax 3.2.2 (Apache-2.0) plus `render.html`.
- `Resources/AppIcon.icns`: the app icon.
- `scripts/build_app.sh`: builds, signs, installs and launches `Pri Notes.app`.
- `scripts/make_icon.swift`: generates `Resources/AppIcon.icns`.
- `docs/NOTES.md`: design notes, verification status and known limitations.
- `docs/learnings.md`: how the app works, with flowcharts and pseudocode: macOS app anatomy, event taps,
  the Accessibility API, and how it reads and edits Notes.

## Licence

MIT; see [LICENSE](LICENSE). The bundled MathJax 3.2.2 is Apache-2.0; see
[Resources/mathjax/LICENSE](Resources/mathjax/LICENSE).
