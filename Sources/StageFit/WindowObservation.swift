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
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var onExpired: (() -> Void)?

    private func schedule(delay: TimeInterval = 0, _ operation: @escaping @MainActor () async -> Void) {
        let id = UUID(), epoch = generation
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
            catch { return }
            guard let self, self.generation == epoch, !Task.isCancelled else { return }
            await operation()
        }
    }

    init(windows: AccessibilityWindows, enqueue: @escaping (Set<WindowID>) -> Void) {
        self.windows = windows; self.enqueue = enqueue
    }

    func start() {
        guard !tracker.isRunning else { return }
        generation += 1
        tracker.start(existing: [])
        // Baseline enumeration runs off MainActor. Subscribe before it finishes so
        // notifications during startup are not lost.
        let apps = NSWorkspace.shared.runningApplications.filter(AccessibilityWindows.isEligible)
        schedule { [weak self] in
            guard let self else { return }
            for app in apps {
                let existing = await self.windows.windows(pid: app.processIdentifier)
                guard !Task.isCancelled else { return }
                self.tracker.baseline(existing)
                self.attachWithRetries(app)
            }
        }
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

    func complete(_ ids: Set<WindowID>, retryable: Set<WindowID>) {
        guard tracker.isRunning else { return }
        let result = tracker.complete(ids, retryable: retryable, now: ProcessInfo.processInfo.systemUptime)
        if !result.expired.isEmpty { onExpired?() }
        for (delay, retries) in Dictionary(grouping: result.scheduled, by: \.delay) {
            schedule(delay: delay) { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let ready = Set(retries.compactMap { self.tracker.claimRetry($0.id, now: now) ? $0.id : nil })
                if !ready.isEmpty { self.enqueue(ready) }
                if ready.count < retries.count, self.tracker.isRunning { self.onExpired?() }
            }
        }
    }

    func stop() {
        generation += 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        debounce?.cancel(); debounce = nil; pending.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }; tokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll(); tracker.stop()
    }

    private func attachWithRetries(_ app: NSRunningApplication) {
        for delay in [0.0, 0.3, 1.0, 2.0] {
            schedule(delay: delay) { [weak self] in await self?.attach(app) }
        }
    }

    private func attach(_ app: NSRunningApplication) async {
        guard tracker.isRunning, AccessibilityWindows.isEligible(app) else { return }
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
        let ids = await windows.windows(pid: pid)
        guard !Task.isCancelled, tracker.isRunning else { return }
        queue(tracker.discover(ids, pid: pid))
    }

    private func discover(pid: pid_t) {
        guard tracker.isRunning else { return }
        for delay in [0.0, 0.25, 0.75, 1.75, 3.75] {
            schedule(delay: delay) { [weak self] in
                guard let self, self.tracker.isRunning else { return }
                let ids = await self.windows.windows(pid: pid)
                guard !Task.isCancelled else { return }
                self.queue(self.tracker.discover(ids, pid: pid))
            }
        }
    }

    private func detach(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        tracker.remove(pid: pid)
        Task { await windows.remove(pid: pid) }
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
