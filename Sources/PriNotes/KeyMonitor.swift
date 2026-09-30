import AppKit
import PriNotesCore

/// Global keyboard/mouse tap for Apple Notes.
///
/// While Notes is frontmost it reports three things, each delivered on the main thread
/// *after* Notes has processed the event (so text read back via Accessibility is current):
/// - `onTrigger`: a character that can complete a Markdown pattern was typed.
/// - `onActivity`: any key or click — the cursor may have moved (drives the live preview).
/// - `onHotkey`: ⌃⌘E was pressed (swallowed).
/// - `onEscape`: Esc was pressed (passed through to Notes).
/// - `onUnderlineShortcut`: ⌘U was pressed; swallowed and handled by the app (see SelectionStyler).
final class KeyMonitor {
    /// Tag placed on events we synthesize ourselves so the tap can ignore them.
    static let syntheticMarker: Int64 = 0x4E4D_4421   // "NMD!"
    /// ⌃⌘E — toggle an equation between rendered and source form.
    static let hotkeyCode: Int64 = 14                  // kVK_ANSI_E

    var onTrigger: (() -> Void)?
    var onActivity: (() -> Void)?
    var onHotkey: (() -> Void)?
    /// Called when Notes stops being the frontmost app.
    var onNotesDeactivated: (() -> Void)?
    /// Called when Esc is pressed in Notes (the key still reaches Notes).
    var onEscape: (() -> Void)?
    /// Called for ⌘U in Notes. The key is swallowed: Notes' own Underline can't switch underline off.
    var onUnderlineShortcut: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var notesIsFrontmost = false

    init() {
        let ws = NSWorkspace.shared
        notesIsFrontmost = ws.frontmostApplication?.bundleIdentifier == NotesAX.bundleID
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let wasFrontmost = self.notesIsFrontmost
            self.notesIsFrontmost = app?.bundleIdentifier == NotesAX.bundleID
            if wasFrontmost && !self.notesIsFrontmost { self.onNotesDeactivated?() }
        }
    }

    /// Installs the event tap. Fails (returns false) until Accessibility access is granted.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: keyMonitorCallback, userInfo: refcon) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true if the event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard notesIsFrontmost,
              event.getIntegerValueField(.eventSourceUserData) != KeyMonitor.syntheticMarker else { return false }

        if type == .leftMouseUp {
            after(milliseconds: 30) { $0.onActivity?() }
            return false
        }
        guard type == .keyDown else { return false }

        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if modifiers == [.maskCommand, .maskControl],
           event.getIntegerValueField(.keyboardEventKeycode) == KeyMonitor.hotkeyCode {
            after(milliseconds: 0) { $0.onHotkey?() }
            return true
        }
        if modifiers == [.maskCommand], event.getIntegerValueField(.keyboardEventKeycode) == 32 {   // ⌘U
            after(milliseconds: 0) { $0.onUnderlineShortcut?() }
            return true
        }
        if event.getIntegerValueField(.keyboardEventKeycode) == 53 {   // kVK_Escape
            after(milliseconds: 0) { $0.onEscape?() }
        }
        after(milliseconds: 60) { $0.onActivity?() }
        if !modifiers.intersection([.maskCommand, .maskControl]).isEmpty { return false }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        if length > 0, let ch = String(utf16CodeUnits: chars, count: length).first,
           Rules.triggerCharacters.contains(ch) {
            // Give Notes a moment to insert the character before we read the text back.
            after(milliseconds: 20) { $0.onTrigger?() }
        }
        return false
    }

    private func after(milliseconds: Int, _ body: @escaping (KeyMonitor) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            if let self { body(self) }
        }
    }
}

private func keyMonitorCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon, Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
