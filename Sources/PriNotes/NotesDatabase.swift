import Foundation
import SQLite3

/// Read-only access to Notes' own database, for backlinks: the notes that link to a given note.
///
/// Notes keeps everything in `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`
/// (Core Data, one big table `ZICCLOUDSYNCINGOBJECT`). Neither AppleScript nor Accessibility exposes
/// note links: a `>>` link is an inline attachment, which AppleScript leaves out of `body`,
/// `plaintext` and `attachments`. In the database every link is a row (verified with
/// `--notes-db-probe`, macOS 27):
///
/// | column | value |
/// |---|---|
/// | `ZTYPEUTI1` | `com.apple.notes.inlinetextattachment.link` |
/// | `ZTOKENCONTENTIDENTIFIER` | `applenotes://showNote?identifier=<target UUID>[&paragraphID=…]` |
/// | `ZNOTE1` | `Z_PK` of the note containing the link |
/// | `ZMARKEDFORDELETION` | 1 once the link was deleted |
///
/// Notes themselves have `ZIDENTIFIER` (the UUID that links and the editor's AX identifier use),
/// `ZTITLE1`, `ZFOLDER`, `ZMODIFICATIONDATE1` and `ZMARKEDFORDELETION`; folders have `ZTITLE2` and
/// `ZFOLDERTYPE` (1 = Recently Deleted).
///
/// Reading the group container needs Full Disk Access. The database is opened read-only, and
/// nothing leaves the Mac. The column names are Core Data's and can change with a macOS update;
/// a failing query is reported as `.failed`, never guessed around.
///
/// Example:
/// ```swift
/// switch NotesDatabase.backlinks(to: "840B4A13-4518-4BDA-A3AC-7FC087602750") {
/// case .links(let notes): notes.forEach { print($0.title, $0.folder ?? "") }   // "BL Source Notes"
/// case .noAccess: print("grant Full Disk Access")
/// case .failed(let message): print(message)
/// }
/// ```
enum NotesDatabase {
    static let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

    /// A note that links to the note being viewed.
    struct Backlink: Equatable, Sendable {
        /// The note's UUID (`ZIDENTIFIER`).
        let identifier: String
        let title: String
        let folder: String?
        /// The link Notes itself uses to open the note.
        var url: URL? { URL(string: "applenotes://showNote?identifier=\(identifier)") }
    }

    enum Lookup: Equatable, Sendable {
        case links([Backlink])
        /// The database can't be read: Full Disk Access hasn't been granted.
        case noAccess
        case failed(String)
    }

    /// The notes containing a live link to the note with UUID `identifier`, most recently edited
    /// first. Links that were deleted, notes in Recently Deleted and the note itself are left out.
    /// Safe to call from any thread; a fresh read-only connection is used each time.
    static func backlinks(to identifier: String) -> Lookup {
        // TCC refuses the open itself without Full Disk Access; POSIX permissions would say yes.
        guard FileHandle(forReadingAtPath: path) != nil else { return .noAccess }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .failed("open: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_busy_timeout(db, 100)   // WAL readers don't wait for writers; only a checkpoint can hold us

        let sql = """
            SELECT n.ZIDENTIFIER, n.ZTITLE1, f.ZTITLE2
            FROM ZICCLOUDSYNCINGOBJECT a
            JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = a.ZNOTE1
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
            WHERE a.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.link'
              AND (a.ZTOKENCONTENTIDENTIFIER LIKE 'applenotes://showNote?identifier=' || ?1
                   OR a.ZTOKENCONTENTIDENTIFIER LIKE 'applenotes://showNote?identifier=' || ?1 || '&%')
              AND IFNULL(a.ZMARKEDFORDELETION, 0) = 0
              AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0
              AND IFNULL(f.ZFOLDERTYPE, 0) != 1
              AND n.ZIDENTIFIER != ?1
            GROUP BY n.Z_PK
            ORDER BY MAX(IFNULL(n.ZMODIFICATIONDATE1, 0)) DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failed("query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT: SQLite copies the string.
        sqlite3_bind_text(stmt, 1, identifier, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var links: [Backlink] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return .failed("step: \(String(cString: sqlite3_errmsg(db)))") }
            func column(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            guard let id = column(0) else { continue }
            let title = column(1).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            links.append(Backlink(identifier: id, title: title, folder: column(2)))
        }
        return .links(links)
    }
}
