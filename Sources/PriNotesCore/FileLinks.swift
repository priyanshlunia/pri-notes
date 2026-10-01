import Foundation

/// Cross-device links to iCloud Drive items, using the iPhone Files app's `shareddocuments://` scheme.
///
/// A link stores the item's **iPhone** path, so the iPhone opens it natively:
///
///     shareddocuments:///private/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/Research/paper.pdf
///
/// macOS has no handler for the scheme, so Pri Notes registers for it and uses `macPath(for:home:)`
/// to find the same item under `~/Library/Mobile Documents`. Both devices lay out
/// `Mobile Documents` identically: `com~apple~CloudDocs` is iCloud Drive, and `iCloud~<app>` folders
/// are app containers (for example Obsidian's `iCloud~md~obsidian/Documents`).
///
/// Example:
/// ```swift
/// let home = "/Users/me"
/// let url = FileLinks.link(forMacPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a b.txt", home: home)!
/// // shareddocuments:///private/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/a%20b.txt
/// FileLinks.macPath(for: url, home: home)
/// // "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a b.txt"
/// ```
public enum FileLinks {
    public static let scheme = "shareddocuments"

    /// The iPhone's `Mobile Documents` folder. The Files app also accepts it without `/private`.
    static let iosRoots = ["/private/var/mobile/Library/Mobile Documents", "/var/mobile/Library/Mobile Documents"]

    /// The Mac path a `shareddocuments://` link points at, or nil if the link isn't one we open.
    ///
    /// Only items inside `Mobile Documents` are accepted, and `.` or `..` components are refused,
    /// because a link in a shared note could otherwise point anywhere on disk.
    /// The returned path is not checked for existence.
    public static func macPath(for url: URL, home: String) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host.map(\.isEmpty) ?? true else { return nil }
        let path = url.path(percentEncoded: false)
        for root in iosRoots where path.hasPrefix(root + "/") {
            let rest = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard !rest.isEmpty, !rest.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            return home + "/Library/Mobile Documents/" + rest.joined(separator: "/")
        }
        return nil
    }

    /// The `shareddocuments://` link for a Mac path inside `~/Library/Mobile Documents`, or nil if the
    /// path is outside it (such an item isn't in iCloud, so the iPhone couldn't open it).
    public static func link(forMacPath path: String, home: String) -> URL? {
        let root = home + "/Library/Mobile Documents"
        guard path.hasPrefix(root + "/") else { return nil }
        let rest = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        guard !rest.isEmpty, !rest.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let iosPath = iosRoots[0] + "/" + rest.joined(separator: "/")
        guard let encoded = iosPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: scheme + "://" + encoded)
    }
}
