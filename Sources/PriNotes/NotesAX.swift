import AppKit
import ApplicationServices

/// Thin wrapper around the Accessibility (AX) API for one running Apple Notes process.
///
/// Everything here must run on the main thread. Offsets are UTF-16 units, matching
/// `NSString` and `AXSelectedTextRange`.
final class NotesAX {
    static let bundleID = "com.apple.Notes"

    let pid: pid_t
    private let app: AXUIElement
    /// Menu items found by title, cached because walking the menu bar costs ~10 ms.
    private var menuCache: [String: AXUIElement] = [:]

    init(pid: pid_t) {
        self.pid = pid
        self.app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
    }

    /// Notes as a running app, if it is running.
    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// True while Notes is the frontmost app (its menu items are disabled otherwise).
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // MARK: - Reading the note

    /// The focused note body, or nil if focus is elsewhere (search field, sidebar, …).
    func focusedTextArea() -> AXUIElement? {
        guard let el: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let role: String? = attribute(el, kAXRoleAttribute)
        return role == (kAXTextAreaRole as String) ? el : nil
    }

    /// The note editor in Notes' focused window, whether or not it has keyboard focus: the scroll
    /// area Notes identifies as "Note Body Scroll View" and the note's text area inside it.
    /// Returns nil when the window shows no note (gallery view, an empty folder, Settings…).
    ///
    /// Seen in lab phase 11 (macOS 27): AXWindow ▸ AXSplitGroup ▸ AXScrollArea "Note Body Scroll
    /// View" ▸ AXTextArea "Note[id=<UUID>]" next to an AXScrollBar. The search is breadth-first and
    /// bounded, so a changed hierarchy costs a little time rather than failing.
    func noteEditor() -> (scrollArea: AXUIElement, textArea: AXUIElement, window: AXUIElement)? {
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let identifier: String? = attribute(element, "AXIdentifier")
            if identifier == "Note Body Scroll View",
               let children: [AXUIElement] = attribute(element, kAXChildrenAttribute),
               let text = children.first(where: { (attribute($0, kAXRoleAttribute) as String?) == (kAXTextAreaRole as String) }) {
                return (element, text, window)
            }
            guard depth < 8, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    /// The window currently focused in Notes.
    func focusedWindow() -> AXUIElement? {
        attribute(app, kAXFocusedWindowAttribute)
    }

    /// Screen frame of an element, top-left origin (as AX reports it), or nil once it's gone.
    func frame(of el: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(el, kAXPositionAttribute), let s: AXValue = attribute(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The UUID of the note shown in a note text area, from its AX identifier `Note[id=<UUID>]`.
    /// It is the note's `ZIDENTIFIER` in Notes' database and the id in `applenotes://` links
    /// (verified with `--notes-db-probe --identifier`).
    func noteIdentifier(of textArea: AXUIElement) -> String? {
        guard let raw: String = attribute(textArea, "AXIdentifier"), raw.hasPrefix("Note[id="), raw.hasSuffix("]") else { return nil }
        let id = String(raw.dropFirst("Note[id=".count).dropLast())
        return id.isEmpty ? nil : id
    }

    /// Give an element keyboard focus (e.g. the note text after a click in the note list).
    @discardableResult
    func focus(_ el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// The note's full text, in the same UTF-16 coordinates as `AXSelectedTextRange`.
    ///
    /// Collapsed sections: `AXValue` leaves out the body of every collapsed heading, but the
    /// selection, `AXNumberOfCharacters` and the parameterized attributes all count the full
    /// storage (seen 2026-10-07, macOS 27: value 1322 units, 2044 characters, cursor at 1031 in
    /// storage terms). Slicing the short value with the selection reads the wrong text, so Markdown
    /// detection silently failed below a collapsed section. When the two lengths disagree, read the
    /// whole storage with `AXStringForRange` instead.
    ///
    /// Example: `let text = ax.value(of: el); let sel = ax.selectedRange(of: el)` — `sel` indexes `text`.
    func value(of el: AXUIElement) -> NSString? {
        guard let shown: String = attribute(el, kAXValueAttribute) else { return nil }
        let value = shown as NSString
        guard let count: Int = attribute(el, kAXNumberOfCharactersAttribute), count != value.length else { return value }
        var cf = CFRange(location: 0, length: count)
        var result: CFTypeRef?
        guard let rangeValue = AXValueCreate(.cfRange, &cf),
              AXUIElementCopyParameterizedAttributeValue(
                el, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
              let full = result as? String, (full as NSString).length == count
        else { return value }
        return full as NSString
    }

    func selectedRange(of el: AXUIElement) -> NSRange? {
        guard let v: AXValue = attribute(el, kAXSelectedTextRangeAttribute) else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(v, .cfRange, &cf) else { return nil }
        return NSRange(location: cf.location, length: cf.length)
    }

    /// Font family/name of the character at `location`, used to skip conversions inside
    /// monostyled (code) paragraphs. Returns nil if Notes doesn't expose it.
    func fontName(of el: AXUIElement, at location: Int) -> String? {
        var cf = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cf) else { return nil }
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &result)
        guard err == .success, let attributed = result as? NSAttributedString, attributed.length > 0 else { return nil }
        let attrs = attributed.attributes(at: 0, effectiveRange: nil)
        if let font = attrs[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any] {
            return (font[kAXFontNameKey.takeUnretainedValue() as String] ?? font[kAXFontFamilyKey.takeUnretainedValue() as String]) as? String
        }
        return (attrs[.font] as? NSFont)?.fontName
    }

    /// Point size of the character before `location` (falls back to 13 pt, Notes' body size).
    func fontSize(of el: AXUIElement, at location: Int) -> CGFloat {
        var cf = CFRange(location: max(0, location), length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cf) else { return 13 }
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &result)
        guard err == .success, let attributed = result as? NSAttributedString, attributed.length > 0 else { return 13 }
        let attrs = attributed.attributes(at: 0, effectiveRange: nil)
        if let font = attrs[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
           let size = font[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber {
            return CGFloat(size.doubleValue)
        }
        return (attrs[.font] as? NSFont)?.pointSize ?? 13
    }

    // MARK: - Editing the note

    @discardableResult
    func setSelectedRange(of el: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Replace the text in `range` with `text` (goes through Notes' normal editing path, so ⌘Z undoes it).
    @discardableResult
    func replace(in el: AXUIElement, range: NSRange, with text: String) -> Bool {
        guard setSelectedRange(of: el, range) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: - Menu commands and keystrokes

    /// Press the first menu item titled `title` under Notes' Format menu (searched recursively,
    /// so Format ▸ Font ▸ Bold is found too). Returns false if no enabled item was found.
    @discardableResult
    func pressMenuItem(_ title: String) -> Bool {
        pressMenuItem(path: [title])
    }

    /// Press a menu item identified by a path of titles, where each title is searched for
    /// (recursively) inside the previous one — e.g. `["Baseline", "Use Default"]` finds
    /// Format ▸ Font ▸ Baseline ▸ Use Default rather than Kern ▸ Use Default.
    @discardableResult
    func pressMenuItem(path: [String]) -> Bool {
        let key = path.joined(separator: " ▸ ")
        if let cached = menuCache[key], AXUIElementPerformAction(cached, kAXPressAction as CFString) == .success {
            return true
        }
        menuCache[key] = nil
        guard var current: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return false }
        for (index, title) in path.enumerated() {
            guard let found = findMenuItem(titled: title, under: current, depth: index == 0 ? 0 : 1) else {
                Log.write("menu item not found: \(key)")
                return false
            }
            current = found
        }
        menuCache[key] = current
        return AXUIElementPerformAction(current, kAXPressAction as CFString) == .success
    }

    /// Screen rectangle (top-left origin, as AX reports it) of the characters in `range`.
    func bounds(of el: AXUIElement, range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cf) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private func findMenuItem(titled title: String, under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            let childTitle: String? = attribute(child, kAXTitleAttribute)
            let role: String? = attribute(child, kAXRoleAttribute)
            if depth == 0 {
                // Top level: only descend into the Format menu (and Edit, as a fallback for odd layouts).
                guard childTitle == "Format" || childTitle == "Edit" else { continue }
            } else if role == (kAXMenuItemRole as String), childTitle == title {
                return child
            }
            if let found = findMenuItem(titled: title, under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Send a key combination straight to Notes (not through the global event stream).
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: KeyMonitor.syntheticMarker)
            e.postToPid(pid)
        }
    }

    // MARK: - Generic attribute access

    private func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        // CF types can't be conditionally cast with `as?`; check the CF type ID instead.
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }
}

extension NSPasteboard {
    /// Wait, running the run loop, until something writes to the pasteboard after `count` (a
    /// `changeCount` read before pressing a Copy menu item), or `timeout` seconds pass. Returns
    /// whether it changed. Notes' Copy is synchronous, but Copy Style and Copy as Markdown can lag.
    ///
    /// Example:
    /// ```swift
    /// let before = pb.changeCount
    /// ax.pressMenuItem("Copy as Markdown")
    /// guard pb.waitForChange(since: before, timeout: 1.5) else { return }
    /// ```
    @discardableResult
    func waitForChange(since count: Int, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while changeCount == count, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return changeCount != count
    }
}
