import AppKit
import PriNotesCore

/// ⌃⌘K and the toolbar's link button: pick an item in iCloud Drive and insert a `shareddocuments://`
/// link to it (see `FileLinks`), which opens the item on iPhone (Files) and on Mac (`FileLinkOpener`).
///
/// With text selected, the selection becomes the link. Otherwise the item's name is inserted at the
/// cursor, followed by a plain space so that typing continues outside the link.
///
/// The picker belongs to Pri Notes, so Notes goes to the background while it is open, and Notes'
/// menu items (needed for Paste) only work while Notes is frontmost. So Notes is brought back to the
/// front before pasting, and the paste is skipped if the note's text changed in the meantime
/// (for example, the user clicked into another note), because the saved range would be wrong.
@MainActor
final class FileLinkInserter {
    private let formatter: Formatter
    private var isPicking = false

    init(formatter: Formatter) {
        self.formatter = formatter
    }

    func run() {
        guard !isPicking, let ctx = formatter.currentContext() else { return }
        isPicking = true
        defer { isPicking = false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let selectedText = ctx.selection.length > 0 ? ctx.text.substring(with: ctx.selection) : nil

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        panel.message = "Choose a file or folder in iCloud Drive. The link opens it on your Mac and iPhone."
        panel.prompt = "Link"
        NSApp.activate()
        let response = panel.runModal()

        var link: URL?
        var title = selectedText ?? ""
        if response == .OK, let picked = panel.url {
            let path = picked.resolvingSymlinksInPath().path
            link = FileLinks.link(forMacPath: path, home: home)
            if link == nil {
                // Still frontmost, so the alert shows before Notes comes back.
                let alert = NSAlert()
                alert.messageText = "Not in iCloud Drive"
                alert.informativeText = "“\(picked.lastPathComponent)” isn’t in iCloud Drive, so your iPhone couldn’t open a link to it."
                alert.runModal()
            }
            if selectedText == nil { title = FileManager.default.displayName(atPath: path) }
        }

        guard formatter.styler.ensureNotesFrontmost() else {
            Log.write("file link: Notes didn't come back to the front")
            return
        }
        guard let link else {
            ctx.ax.setSelectedRange(of: ctx.element, ctx.selection)   // cancelled: leave things as they were
            return
        }
        guard let now = formatter.currentContext(), now.text.isEqual(to: ctx.text as String) else {
            Log.write("file link: note changed while the picker was open")
            NSSound.beep()
            return
        }
        formatter.pasteLink(text: title, url: link, over: ctx.selection, trailingSpace: selectedText == nil,
                            ax: now.ax, el: now.element)
    }
}
