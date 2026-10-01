import AppKit
import PriNotesCore
import UniformTypeIdentifiers

/// Opens `shareddocuments://` links on the Mac (see `FileLinks`). Notes hands the click to
/// LaunchServices, which routes the scheme to Pri Notes through `CFBundleURLTypes` in Info.plist.
///
/// Folders open in Finder and documents open in their default app, matching what the Files app does
/// on iPhone. Anything that could run code (apps, scripts, executables, location files) is only
/// revealed in Finder: a link in a shared note shouldn't be able to launch a program.
///
/// Example:
/// ```swift
/// FileLinkOpener.open(URL(string: "shareddocuments:///private/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/Research")!)
/// // Finder opens ~/Library/Mobile Documents/com~apple~CloudDocs/Research
/// ```
@MainActor
enum FileLinkOpener {
    /// Types that are revealed instead of opened, because opening them runs or redirects to something.
    private static let revealOnlyTypes: [UTType] = [
        .application, .executable, .script, .shellScript, .unixExecutable, .internetLocation,
        UTType("com.apple.file-internet-location") ?? .internetLocation,
    ]

    static func open(_ url: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let path = FileLinks.macPath(for: url, home: home) else {
            Log.write("file link: not an iCloud Drive link")
            return alert("This link doesn’t point inside iCloud Drive, so Pri Notes won’t open it.")
        }
        let item = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            Log.write("file link: target missing")
            return alert("Couldn’t find “\(item.lastPathComponent)” in iCloud Drive. It may have been moved, renamed or deleted.")
        }

        let values = try? item.resourceValues(forKeys: [.contentTypeKey, .isExecutableKey])
        let type = values?.contentType
        let runsCode = revealOnlyTypes.contains { type?.conforms(to: $0) ?? false }
            || (!isDirectory.boolValue && values?.isExecutable == true)
        if runsCode {
            NSWorkspace.shared.activateFileViewerSelecting([item])
        } else if !NSWorkspace.shared.open(item) {
            Log.write("file link: open failed")
            NSWorkspace.shared.activateFileViewerSelecting([item])
        }
    }

    private static func alert(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Can’t open link"
        alert.informativeText = message
        alert.runModal()
    }
}
