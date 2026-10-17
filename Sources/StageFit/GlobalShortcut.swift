import AppKit
import Carbon
import StageFitCore

@MainActor enum KeyboardLayout {
    static func character(for code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                    UInt32(kUCKeyTranslateNoDeadKeysMask), &dead, buffer.count, &length, &buffer)
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    static func description(_ shortcut: Shortcut) -> String {
        let modifiers = shortcut.modifiers
        return (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
               (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
               (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
               (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + shortcut.label
    }

    static func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
                                        123: "←", 124: "→", 125: "↓", 126: "↑"]
        let label = special[event.keyCode] ?? character(for: event.keyCode)?.uppercased() ?? "Key \(event.keyCode)"
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
}

struct ShortcutFailure: LocalizedError {
    let code: OSStatus
    var errorDescription: String? {
        "This shortcut could not be registered (macOS \(code)). Check whether another app uses it, or choose another combination."
    }
}

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var current: Shortcut?
    var onPress: (() -> Void)?
    private static let signature: OSType = 0x53465431 // SFT1

    func register(_ shortcut: Shortcut) throws {
        guard shortcut.isValid else { throw ShortcutFailure(code: OSStatus(paramErr)) }
        if let current, current.keyCode == shortcut.keyCode && current.modifiers == shortcut.modifiers, hotKey != nil {
            self.current = shortcut
            return
        }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identity = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identity)
                guard result == noErr, identity.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.onPress?() }
                return noErr
            }
            let result = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { throw ShortcutFailure(code: result) }
        }
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: 1),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
        guard result == noErr, let candidate else { throw ShortcutFailure(code: result) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; current = shortcut
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil; current = nil
    }

    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil; onPress = nil
    }
}

@MainActor private final class RecorderView: NSView {
    var receive: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { receive?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { receive?(event); return true }
}

@MainActor final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let message = NSTextField(wrappingLabelWithString: "Press a shortcut containing Option, Control or Command. Escape cancels.")
    private let save: (Shortcut) throws -> Void
    private let closed: () -> Void
    private var didClose = false

    init(save: @escaping (Shortcut) throws -> Void, closed: @escaping () -> Void) {
        self.save = save; self.closed = closed
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 150),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "StageFit Shortcut"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        let content = RecorderView(frame: panel.contentView!.bounds)
        content.receive = { [weak self] event in self?.receive(event) }
        message.frame = NSRect(x: 24, y: 62, width: 382, height: 65)
        content.addSubview(message)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 318, y: 16, width: 90, height: 32)
        content.addSubview(cancel)
        panel.contentView = content
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content)
    }

    func show() { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    func close() { panel.close() }
    @objc private func cancel() { panel.close() }
    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true; closed()
    }

    private func receive(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { panel.close(); return }
        guard let shortcut = KeyboardLayout.shortcut(from: event), shortcut.isValid else {
            message.stringValue = "Include Option, Control or Command with another key."
            return
        }
        do { try save(shortcut); panel.close() }
        catch { message.stringValue = error.localizedDescription }
    }
}
