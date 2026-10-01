# Developing Pri Notes

How to build, test and find your way around the code. To install the app (signing certificate,
build, Accessibility grant), see the [README](../README.md#install). For how the app works, with
diagrams, see [learnings.md](learnings.md).

Everything builds with the Xcode Command Line Tools alone; XCTest isn't available, so the tests are a
plain executable.

## Tests and debug tools

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

## In-Notes regression tests

These run in the focused note, only if it starts with "PRI-LAB", and they
rewrite that note. Keep Notes in front and hands off while they run.

```bash
open -n ~/Applications/Pri\ Notes.app --args --notes-lab /tmp/lab.txt --phase3
```

- `--phase3`: toolbar changes.
- `--phase4`: equations after styled text, and colour matching.
- `--phase7`: B/I/U/S on and off.
- `--phase8`: ⌃⌘E on text equations mid-sentence.

Read the report in `/tmp/lab.txt` afterwards.

## App icon

The app icon is drawn by `scripts/make_icon.swift`, a dark-mode Notes-style pad with an italic Palatino
"P". Regenerate it, then rerun `scripts/build_app.sh`:

```bash
swiftc -O -o /tmp/make_icon scripts/make_icon.swift && /tmp/make_icon Resources/AppIcon.icns
```

## Source layout

- `Sources/PriNotesCore/`: pure logic, covered by `selftest`.
  - `Rules.swift`: which Markdown or math pattern ends at the cursor.
  - `MathSpans.swift`: finds `$…$` and `$$…$$` spans on a line, for the preview and the in-math guard.
  - `LatexUnicode.swift`: LaTeX to text, as `MathRun`s with script level and italic flag.
  - `StyleSample.swift`: the RTF style sample for Paste Style (keeps the system font) and font conversions.
  - `FileLinks.swift`: iCloud Drive path ↔ `shareddocuments://` link, with the safety checks.
- `Sources/PriNotes/`: the app.
  - `main.swift`: app delegate, menu, settings, debug modes.
  - `KeyMonitor.swift`: global key and click tap, active only while Notes is frontmost; ⌃⌘E, ⌃⌘K and ⌘U.
  - `SelectionToolbar.swift`, `SelectionStyler.swift`: the Liquid Glass toolbar, and reading and
    applying styles (Paste Style, toggles, underline removal).
  - `NotesAX.swift`: Accessibility access to Notes (text, selection, fonts, bounds, menu items).
  - `Formatter.swift`: applies each action to the note, and handles ⌃⌘E re-editing.
  - `MathRenderer.swift`: locked-down, offline MathJax WebView, TeX to PNG.
  - `PreviewPanel.swift`: the live equation preview panel.
  - `EquationStore.swift`: equation history used for re-editing.
  - `FileLinkInserter.swift`, `FileLinkOpener.swift`: ⌃⌘K and the toolbar's link button; opening
    clicked file links on the Mac.
  - `MenuBarIcon.swift`: the menu-bar icon.
  - `Lab.swift`: the `--notes-lab` in-Notes experiment and regression harness.
  - `Log.swift`: the error log.
- `Sources/selftest/main.swift`: assertion tests (XCTest isn't available with the Command Line Tools
  alone).
- `Resources/mathjax/`: MathJax 3.2.2 (Apache-2.0) plus `render.html`.
- `Resources/AppIcon.icns`: the app icon.
- `scripts/build_app.sh`: builds, signs, installs and launches `Pri Notes.app`.
- `scripts/make_icon.swift`: generates `Resources/AppIcon.icns`.
- `docs/developer.md`: this file.
- `docs/learnings.md`: how the app works, with flowcharts and pseudocode: macOS app anatomy, event taps,
  the Accessibility API, and how it reads and edits Notes.

