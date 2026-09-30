import Foundation

/// Remembers the LaTeX source of every equation the app converts, so it can be turned back
/// into editable `$…$` / `$$…$$` text later (⌃⌘E).
///
/// Stored as JSON in `~/Library/Application Support/PriNotes/equations.json`, newest last,
/// capped at `limit` entries.
///
/// - Unicode (`$…$`) equations are found again by their exact converted text.
/// - Image (`$$…$$`) equations are found by the SHA-256 of their pixels (see
///   `MathRenderer.pixelHash`); the source is also embedded in the PNG itself as a first choice.
@MainActor
final class EquationStore {
    struct Entry: Codable {
        var source: String
        var display: Bool
        /// Converted text for Unicode equations.
        var text: String?
        /// Pixel hash for image equations.
        var pixelHash: String?
        var date: Date
    }

    private(set) var entries: [Entry] = []
    private let url: URL
    private let limit = 5000

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("PriNotes", isDirectory: true)
        // Versions before the rename kept their history in "NotesMarkdown"; move it over once, so
        // equations converted back then can still be re-edited.
        let legacyDir = support.appendingPathComponent("NotesMarkdown", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("equations.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    func add(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    /// Most recent Unicode equation whose converted text equals `text`.
    func source(forText text: String) -> Entry? {
        entries.last { $0.text == text }
    }

    /// The most recent Unicode equation, if its converted text sits just before the cursor
    /// (`prefix` = note text up to the cursor). Only the latest conversion is considered, so a
    /// short result like "x" can't be confused with ordinary text; older equations must be selected.
    func latestUnicodeEntry(endingAt prefix: String) -> Entry? {
        guard let latest = entries.last(where: { $0.text != nil }), let text = latest.text,
              !text.isEmpty, prefix.hasSuffix(text) else { return nil }
        return latest
    }

    func source(forPixelHash hash: String) -> Entry? {
        entries.last { $0.pixelHash == hash }
    }
}
