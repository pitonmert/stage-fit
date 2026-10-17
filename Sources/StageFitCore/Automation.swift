import CoreGraphics
import Foundation

// Window identity stays stable when an application changes its title.
public struct NewWindowTracker {
    private var known: Set<WindowID> = []
    public private(set) var isRunning = false
    public init() {}

    public mutating func start(existing: Set<WindowID>, includeExisting: Bool) -> Set<WindowID> {
        guard !isRunning else { return [] }
        isRunning = true; known = existing
        return includeExisting ? existing : []
    }

    public mutating func discover(_ ids: Set<WindowID>, pid: Int32) -> Set<WindowID> {
        guard isRunning else { return [] }
        let fresh = ids.subtracting(known)
        known = known.filter { $0.pid != pid }.union(ids)
        return fresh
    }

    public mutating func remove(pid: Int32) { known = known.filter { $0.pid != pid } }
    public mutating func stop() { isRunning = false; known.removeAll() }
}

@MainActor public final class LayoutQueue {
    public enum Job: Equatable, Sendable { case manual; case automatic(Set<WindowID>) }
    private var pending: [Job] = []
    private var task: Task<Void, Never>?
    private var active: Job?
    private var stopped = false
    private let perform: @MainActor (Job) async -> Void
    public var isBusy: Bool { task != nil }

    public init(perform: @escaping @MainActor (Job) async -> Void) { self.perform = perform }

    public func submit(_ job: Job) {
        guard !stopped else { return }
        switch job {
        case .manual:
            if !pending.contains(.manual) { pending.append(job) }
        case .automatic(let ids):
            guard !ids.isEmpty else { return }
            if case .automatic(let old) = pending.last {
                pending[pending.count - 1] = .automatic(old.union(ids))
            } else { pending.append(job) }
        }
        drain()
    }

    public func cancelAutomatic() {
        pending.removeAll { if case .automatic = $0 { return true }; return false }
        if case .automatic = active { task?.cancel() }
    }

    public func stop() {
        stopped = true; pending.removeAll(); task?.cancel()
    }

    private func drain() {
        guard task == nil, !stopped, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        active = job
        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(job)
            self.active = nil; self.task = nil
            self.drain()
        }
    }
}

public struct Shortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    // Carbon's cmdKey, shiftKey, optionKey, controlKey bits. No AppKit dependency in the core.
    public var isValid: Bool {
        keyCode < 128 && modifiers != 0 && modifiers & ~UInt32(0x1B00) == 0 && !label.isEmpty && label.count <= 32
    }
}

public final class Preferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var automaticSizing: Bool {
        get { defaults.object(forKey: "automaticSizing") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticSizing") }
    }
    public var shortcut: Shortcut? {
        get {
            guard let data = defaults.data(forKey: "shortcut"),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data), shortcut.isValid else { return nil }
            return shortcut
        }
        set {
            if let newValue, newValue.isValid, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "shortcut")
            } else { defaults.removeObject(forKey: "shortcut") }
        }
    }
}
