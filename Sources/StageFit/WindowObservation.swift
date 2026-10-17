import AppKit
import ApplicationServices
import StageFitCore

@MainActor final class WindowObservation {
    private let windows: AccessibilityWindows
    private let enqueue: (Set<WindowID>) -> Void
    private var tracker = NewWindowTracker()
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var pending: Set<WindowID> = []
    private var debounce: DispatchWorkItem?
    private var generation = 0

    init(windows: AccessibilityWindows, enqueue: @escaping (Set<WindowID>) -> Void) {
        self.windows = windows; self.enqueue = enqueue
    }

    func start(includeExisting: Bool) {
        guard !tracker.isRunning else { return }
        generation += 1
        let apps = NSWorkspace.shared.runningApplications.filter { windows.isEligible($0) }
        let existing = apps.reduce(into: Set<WindowID>()) { $0.formUnion(windows.windows(of: $1)) }
        queue(tracker.start(existing: existing, includeExisting: includeExisting))
        for app in apps { attachWithRetries(app) }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.attachWithRetries(app) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.detach(app.processIdentifier) }
        })
    }

    func stop() {
        generation += 1
        debounce?.cancel(); debounce = nil; pending.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }; tokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll(); tracker.stop()
    }

    private func attachWithRetries(_ app: NSRunningApplication) {
        let epoch = generation
        for delay in [0.0, 0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.tracker.isRunning, self.generation == epoch else { return }
                self.attach(app)
            }
        }
    }

    private func attach(_ app: NSRunningApplication) {
        guard tracker.isRunning, windows.isEligible(app) else { return }
        let pid = app.processIdentifier
        if observers[pid] == nil {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var observer: AXObserver?
            // The callback below retrieves its app's PID from the notification element.
            let windowCallback: AXObserverCallback = { _, element, _, context in
                guard let context else { return }
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                let owner = Unmanaged<WindowObservation>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.discover(pid: pid) }
            }
            if AXObserverCreate(pid, windowCallback, &observer) == .success, let observer,
               AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString,
                                         Unmanaged.passUnretained(self).toOpaque()) == .success {
                observers[pid] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        // Some apps create their first window before the notification subscription is ready.
        queue(tracker.discover(windows.windows(of: app), pid: pid))
    }

    private func discover(pid: pid_t) {
        guard tracker.isRunning, let app = NSRunningApplication(processIdentifier: pid) else { return }
        queue(tracker.discover(windows.windows(of: app), pid: pid))
        // AXWindowCreated may arrive before AXWindows includes the new element.
        let epoch = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.tracker.isRunning, self.generation == epoch else { return }
            self.queue(self.tracker.discover(self.windows.windows(of: app), pid: pid))
        }
    }

    private func detach(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        tracker.remove(pid: pid); windows.remove(pid: pid)
        pending = pending.filter { $0.pid != pid }
    }

    private func queue(_ ids: Set<WindowID>) {
        guard !ids.isEmpty else { return }
        pending.formUnion(ids)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tracker.isRunning else { return }
            let batch = self.pending
            self.pending.removeAll()
            self.enqueue(batch)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}
