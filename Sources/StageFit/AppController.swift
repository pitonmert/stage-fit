import AppKit
@preconcurrency import ApplicationServices
import OSLog
import StageFitCore

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let windows = AccessibilityWindows()
    private let shortcut = GlobalShortcut()
    private let logger = Logger(subsystem: "com.pitonmert.StageFit", category: "Application")
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var recorder: ShortcutRecorder?
    private var trusted = false
    private var initialSweep = true
    private var lastMessage = "Ready"
    private var shortcutProblem: String?
    private lazy var engine = LayoutEngine(access: windows)
    private lazy var queue = LayoutQueue { [weak self] job in
        guard let self else { return }
        let issues: [LayoutIssue]
        switch job {
        case .manual: issues = await self.engine.arrangeManually()
        case .automatic(let ids): issues = await self.engine.arrangeNewWindows(ids)
        }
        guard !Task.isCancelled else { return }
        if let issue = issues.first {
            self.lastMessage = issue.message
            for issue in issues { self.logger.error("\(issue.message, privacy: .public)") }
            self.updateTooltip()
            if case .manual = job { self.showError(issue.message) }
        } else {
            self.lastMessage = "Ready"; self.updateTooltip()
        }
    }
    private lazy var observation = WindowObservation(windows: windows) { [weak self] ids in
        self?.queue.submit(.automatic(ids))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.lefthalf.inset.filled", accessibilityDescription: "StageFit")
            button.image?.isTemplate = true
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("StageFit")
        }
        statusItem = item
        shortcut.onPress = { [weak self] in self?.arrange() }
        registerPreferredShortcut()
        initialSweep = preferences.automaticSizing
        checkPermission()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermission() }
        }
        updateTooltip()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        permissionTimer?.invalidate(); permissionTimer = nil
        observation.stop()
        queue.stop()
        shortcut.stop()
        // Allow an in-flight transaction to roll back before the process exits.
        Task { [weak self] in
            guard let self else { NSApp.reply(toApplicationShouldTerminate: true); return }
            while self.queue.isBusy { try? await Task.sleep(nanoseconds: 25_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func checkPermission() {
        let allowed = AXIsProcessTrusted()
        guard allowed != trusted else { return }
        trusted = allowed
        if allowed {
            lastMessage = "Ready"
            if preferences.automaticSizing {
                observation.start(includeExisting: initialSweep)
                initialSweep = false
            }
        } else {
            observation.stop(); queue.cancelAutomatic()
            lastMessage = LayoutError.accessibilityRequired.localizedDescription
        }
        updateTooltip()
    }

    private func registerPreferredShortcut() {
        guard let preferred = preferences.shortcut else {
            shortcutProblem = nil
            updateTooltip(); return
        }
        do {
            try shortcut.register(preferred)
            preferences.shortcut = preferred
            shortcutProblem = nil
        } catch {
            shortcutProblem = error.localizedDescription
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
        updateTooltip()
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() }
        else { arrange() }
    }

    @objc private func arrange() {
        guard AXIsProcessTrusted() else {
            showError(LayoutError.accessibilityRequired.localizedDescription)
            return
        }
        queue.submit(.manual)
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let info = NSMenuItem(title: trusted ? lastMessage : "Accessibility permission required", action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        if let problem = shortcutProblem {
            let issue = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            issue.isEnabled = false; menu.addItem(issue)
        }
        menu.addItem(.separator())
        let automatic = NSMenuItem(title: "Automatically Size New Windows", action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self; automatic.state = preferences.automaticSizing ? .on : .off
        menu.addItem(automatic)
        let unavailableLabel = preferences.shortcut == nil ? "Not set" : "Not registered"
        let label = shortcut.current.map(KeyboardLayout.description) ?? unavailableLabel
        add("Change Shortcut… (\(label))", action: #selector(changeShortcut), to: menu)
        add("Open Accessibility Settings…", action: #selector(openAccessibilitySettings), to: menu)
        menu.addItem(.separator())
        add("Quit StageFit", action: #selector(quit), to: menu)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }

    @objc private func toggleAutomatic() {
        preferences.automaticSizing.toggle()
        initialSweep = false
        if preferences.automaticSizing, AXIsProcessTrusted() { observation.start(includeExisting: false) }
        else { observation.stop(); queue.cancelAutomatic() }
        updateTooltip()
    }

    @objc private func changeShortcut() {
        if let recorder { recorder.show(); return }
        // Temporarily release the old hotkey so the recorder can receive the same combination.
        shortcut.unregister()
        recorder = ShortcutRecorder(save: { [weak self] candidate in
            guard let self else { return }
            try self.shortcut.register(candidate)
            self.preferences.shortcut = candidate
            self.shortcutProblem = nil
        }, closed: { [weak self] in
            self?.recorder = nil
            self?.registerPreferredShortcut()
        })
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateTooltip() {
        let state = !trusted ? "Accessibility permission required" : lastMessage
        let unavailableLabel = preferences.shortcut == nil ? "No shortcut set" : "Shortcut unavailable"
        let key = shortcut.current.map(KeyboardLayout.description) ?? unavailableLabel
        statusItem?.button?.toolTip = "StageFit · \(key)\n\(shortcutProblem ?? state)\nLeft-click: arrange · Right-click: options"
    }

    private func showError(_ message: String) {
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = "StageFit"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        previous?.activate(options: [])
    }
}
