import AppKit
import PriNotesCore

/// The note footer's export button: copy the whole note to the clipboard as Markdown, with every
/// Pri Notes equation written as inline LaTeX (`$…$`; equations that were images get their own line).
///
/// Notes (macOS 26+) has Edit ▸ Copy as Markdown, which already handles titles, headings, lists,
/// checklists, emphasis and links. Its output keeps text equations only as their converted
/// characters and image equations as `![Pasted Graphic.png](…)` (lab phase 11), so:
///
/// 1. The text equations are found in the note: a Palatino stretch ended by U+200B (as for the
///    toolbar), whose LaTeX comes from the equation history.
/// 2. If the note has attachments, Edit ▸ Copy of the whole note gives the original PNGs in
///    `com.apple.flat-rtfd`, with the LaTeX in their metadata.
/// 3. Edit ▸ Copy as Markdown of the whole note.
/// 4. `MarkdownEquations.restore` puts the LaTeX back, and the result replaces the clipboard as
///    plain text (and `net.daringfireball.markdown`).
///
/// The note's text isn't changed; the selection is restored afterwards. Text equations converted
/// on another Mac aren't in this Mac's history and stay as Notes wrote them.
///
/// Example: a note "Inline xb2 done." with an image of `\int_0^1 f\,dx` below it is copied as
/// `"# Title  \nInline $x_b^2$ done.  \n$\int_0^1 f\,dx$  \n"`.
@MainActor
final class MarkdownExporter {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    private let formatter: Formatter
    /// Set while an export runs: it spins the run loop, so a second click could start another one.
    private var isExporting = false

    init(formatter: Formatter) {
        self.formatter = formatter
    }

    /// Export the note shown in `textArea` (focused through `ax` first if it isn't). Returns true when the
    /// clipboard holds the Markdown; on failure the error is reported through the formatter.
    @discardableResult
    func copyNote(textArea: AXUIElement?, ax notesAX: NotesAX?) -> Bool {
        guard !isExporting else { return false }
        isExporting = true
        defer { isExporting = false }
        var ctx = formatter.currentContext()
        if ctx == nil, let textArea, let ax = notesAX {
            // The click came while the note list had focus: Copy as Markdown acts on the focused view.
            ax.focus(textArea)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            ctx = formatter.currentContext()
        }
        guard let ctx else {
            formatter.fail("Click into the note, then try Copy as Markdown again.")
            return false
        }
        let (ax, el, text) = (ctx.ax, ctx.element, ctx.text)
        let all = NSRange(location: 0, length: text.length)
        guard all.length > 0 else { formatter.fail("The note is empty."); return false }
        defer { ax.setSelectedRange(of: el, ctx.selection) }

        let equations = textEquations(in: ctx)
        let images = text.range(of: "\u{FFFC}").location == NSNotFound ? [] : attachments(ax: ax, el: el, all: all)

        let pb = NSPasteboard.general
        var markdown: String?
        for attempt in 1...2 where markdown == nil {
            // Once (lab phase 11) the first press copied nothing; a second press has always worked.
            ax.setSelectedRange(of: el, all)
            RunLoop.current.run(until: Date().addingTimeInterval(attempt == 1 ? 0.1 : 0.4))
            let before = pb.changeCount
            guard ax.pressMenuItem("Copy as Markdown") else { break }
            if pb.waitForChange(since: before, timeout: 1.5) {
                markdown = pb.string(forType: Self.markdownType) ?? pb.string(forType: .string)
            }
        }
        guard let markdown else {
            formatter.fail("Notes didn't copy the note as Markdown (Edit ▸ Copy as Markdown needs macOS 26).")
            return false
        }

        let result = MarkdownEquations.restore(in: markdown, textEquations: equations, images: images)
        pb.clearContents()
        pb.setString(result, forType: .string)
        pb.setString(result, forType: Self.markdownType)
        return true
    }

    /// One entry per U+200B in the note, in order: the text equation it ends, or nil (e.g. the
    /// marker after a converted `**bold**`).
    ///
    /// An equation is the Palatino stretch right before the marker; its LaTeX is the history entry
    /// whose converted text the stretch ends with (longest wins), as ⌃⌘E finds it. Requiring
    /// Palatino keeps "bold" (ending in "d") from matching an equation `$d$`.
    private func textEquations(in ctx: Formatter.Context) -> [MarkdownEquations.TextEquation?] {
        let text = ctx.text
        var markers: [Int] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let r = text.range(of: Formatter.zeroWidthSpace, options: [], range: search)
            if r.location == NSNotFound { break }
            markers.append(r.location)
            search = NSRange(location: NSMaxRange(r), length: text.length - NSMaxRange(r))
        }
        guard !markers.isEmpty else { return [] }

        // Palatino stretches, keyed by where they end.
        var stretchEndingAt: [Int: NSRange] = [:]
        var stretch: NSRange?
        let runs = formatter.styler.runs(in: NSRange(location: 0, length: text.length), ax: ctx.ax, el: ctx.element)
        for run in runs {
            if run.style.font.familyName == "Palatino" {
                stretch = stretch.map { NSUnionRange($0, run.range) } ?? run.range
            } else if let s = stretch {
                stretchEndingAt[NSMaxRange(s)] = s
                stretch = nil
            }
        }
        if let s = stretch { stretchEndingAt[NSMaxRange(s)] = s }

        return markers.map { marker in
            guard let range = stretchEndingAt[marker],
                  let entry = formatter.store.unicodeEntry(endingAt: text.substring(with: range)),
                  let converted = entry.text else { return nil }
            return MarkdownEquations.TextEquation(text: converted, source: entry.source)
        }
    }

    /// The note's attachments in order, from Edit ▸ Copy of the whole note: file name, and the
    /// LaTeX for equation images (PNG metadata first, then the pixel hash in the history).
    /// Notes fills the rich text copy lazily, so it is re-read for up to 1.5 s until every
    /// attachment has its data. The clipboard is overwritten by the Markdown afterwards anyway.
    private func attachments(ax: NotesAX, el: AXUIElement, all: NSRange) -> [MarkdownEquations.ImageAttachment] {
        let pb = NSPasteboard.general
        ax.setSelectedRange(of: el, all)
        let before = pb.changeCount
        if !ax.pressMenuItem("Copy") { ax.postKey(8, flags: .maskCommand) }   // ⌘C
        pb.waitForChange(since: before, timeout: 0.5)

        var found: [MarkdownEquations.ImageAttachment] = []
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            var complete = true
            found = []
            if let data = pb.data(forType: NSPasteboard.PasteboardType("com.apple.flat-rtfd")) ?? pb.data(forType: .rtfd),
               let rich = NSAttributedString(rtfd: data, documentAttributes: nil) {
                rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                    guard let attachment = value as? NSTextAttachment else { return }
                    let contents = attachment.fileWrapper?.regularFileContents ?? attachment.contents
                    if contents?.isEmpty ?? true { complete = false }
                    let source = contents.flatMap { Formatter.imageSource($0, store: formatter.store) }
                    found.append(.init(filename: attachment.fileWrapper?.preferredFilename ?? "", source: source))
                }
            } else {
                complete = false
            }
            if complete { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return found
    }
}
