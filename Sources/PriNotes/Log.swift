import Foundation

/// Append-only diagnostic log at ~/Library/Logs/PriNotes.log (trimmed to ~1 MB).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PriNotes.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > 1_000_000 {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
