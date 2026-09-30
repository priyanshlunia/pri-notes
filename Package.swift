// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PriNotes",
    platforms: [.macOS("26.0")],   // Liquid Glass (NSGlassEffectView) needs macOS 26
    targets: [
        // Pure logic (pattern rules, LaTeX conversion/rendering) — no Accessibility code.
        .target(name: "PriNotesCore"),
        // The menu-bar app: event tap + Accessibility driving of Apple Notes.
        .executableTarget(name: "PriNotes", dependencies: ["PriNotesCore"]),
        // `swift run selftest` — assertions for the core logic (XCTest is unavailable with CLT only).
        .executableTarget(name: "selftest", dependencies: ["PriNotesCore"]),
    ]
)
