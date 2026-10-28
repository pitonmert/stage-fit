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
    private var lastMessage = "Ready"
    private var shortcutProblem: String?
    private lazy var engine = LayoutEngine(access: windows)
    private lazy var queue: LayoutQueue = LayoutQueue { [weak self] job in
        guard let self else { return }
        let report: LayoutReport
        switch job {
        case .manual: report = await self.engine.arrangeManually()
        case .swapVisible: report = await self.engine.swapVisibleWindows()
        case .automatic(let ids): report = await self.engine.arrangeNewWindows(ids)
        }
        if Task.isCancelled {
            for issue in report.errors { self.logger.error("\(issue.message, privacy: .public)") }
            return
        }
        if let issue = report.errors.first ?? report.issues.first {
            self.lastMessage = issue.message
            for issue in report.issues {
                if issue.requiresAlert { self.logger.error("\(issue.message, privacy: .public) \(issue.diagnosticDetails, privacy: .public)") }
                else { self.logger.notice("\(issue.message, privacy: .public) \(issue.diagnosticDetails, privacy: .public)") }
            }
            self.updateTooltip()
            if let error = report.errors.first {
                switch job {
                case .manual, .swapVisible: self.showError(error.message)
                case .automatic: break
                }
            }
        } else {
            self.lastMessage = report.retryableIDs.isEmpty ? "Ready" : "Waiting for new windows to become ready."
            self.updateTooltip()
        }
        if case .automatic(let ids) = job { self.observation.complete(ids, retryable: report.retryableIDs) }
    }
    private lazy var observation: WindowObservation = WindowObservation(windows: windows) { [weak self] ids in
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
        observation.onExpired = { [weak self] in
            self?.lastMessage = "A new window did not become ready within the retry limit. Click the menu bar icon to try again."
            self?.logger.notice("A new window exceeded its readiness retry limit.")
            self?.updateTooltip()
        }
        shortcut.onPress = { [weak self] in self?.arrange() }
        registerPreferredShortcut()
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
                observation.start()
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

    @objc private func swapVisibleWindows() {
        guard AXIsProcessTrusted() else {
            showError(LayoutError.accessibilityRequired.localizedDescription)
            return
        }
        queue.submit(.swapVisible)
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .aqua)
        let swap = NSMenuItem(title: "Swap Visible Windows", action: #selector(swapVisibleWindows), keyEquivalent: "")
        swap.target = self; swap.isEnabled = trusted
        menu.addItem(swap)
        let automatic = NSMenuItem(title: "Automatically Size New Windows", action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self; automatic.state = preferences.automaticSizing ? .on : .off
        menu.addItem(automatic)
        let unavailableLabel = preferences.shortcut == nil ? "Not set" : "Not registered"
        let label = shortcut.current.map(KeyboardLayout.description) ?? unavailableLabel
        add("Change Shortcut… (\(label))", action: #selector(changeShortcut), to: menu)
        menu.addItem(.separator())
        add("Quit", action: #selector(quit), to: menu)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }

    @objc private func toggleAutomatic() {
        preferences.automaticSizing.toggle()
        if preferences.automaticSizing, AXIsProcessTrusted() { observation.start() }
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
