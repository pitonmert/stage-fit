import CoreGraphics
import Foundation

public struct WindowID: Hashable, Sendable {
    public let pid: Int32
    public let serial: UInt64
    public init(pid: Int32, serial: UInt64) { self.pid = pid; self.serial = serial }
}

public struct WindowSnapshot: Sendable {
    public let id: WindowID
    public let frame: CGRect
    public let isVisible: Bool
    public let bundleIdentifier: String?
    public init(id: WindowID, frame: CGRect, isVisible: Bool, bundleIdentifier: String? = nil) {
        self.id = id; self.frame = frame; self.isVisible = isVisible
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct DesktopSnapshot: Sendable {
    public let displays: [Display]
    public let windows: [WindowSnapshot]
    public let hiddenGroups: [WindowGroup]
    public init(displays: [Display], windows: [WindowSnapshot], hiddenGroups: [WindowGroup] = []) {
        self.displays = displays; self.windows = windows; self.hiddenGroups = hiddenGroups
    }
}

public enum LayoutError: LocalizedError, Equatable {
    case insufficientSpace, pairDoesNotFit, tooManyWindows, rejectedFrame, unavailableWindow
    case accessibilityRequired, unavailableDisplays
    case restoreFailed
    case widthDoesNotFit(required: CGFloat, available: CGFloat)
    case uncertainGroup, noEligibleWindows, visiblePairRequired

    public var errorDescription: String? {
        switch self {
        case .widthDoesNotFit(let required, let available):
            return "Windows need \(Int(ceil(required))) points; \(Int(floor(available))) are available (\(Int(ceil(required - available))) more needed)."
        case .uncertainGroup: return "Window group membership is changing or unavailable. The group was preserved."
        case .noEligibleWindows: return "No eligible windows are available to arrange."
        case .visiblePairRequired: return "Two visible windows on the same display are required to swap places."
        case .insufficientSpace: return "There is not enough usable space on this display."
        case .pairDoesNotFit: return "These windows cannot fit side by side on this display. Their original layout was preserved."
        case .tooManyWindows: return "Groups with more than two windows are left unchanged."
        case .rejectedFrame: return "A window did not accept the layout. Its original frame was restored."
        case .unavailableWindow: return "A window is no longer available."
        case .accessibilityRequired: return "Allow StageFit in Privacy & Security → Accessibility to arrange windows."
        case .unavailableDisplays: return "Display or visible-window information is unavailable."
        case .restoreFailed: return "A window could not be restored. It may have closed or stopped responding."
        }
    }
}

public struct LayoutIssue: Sendable {
    public let displayID: UInt32?
    public let message: String
    public let diagnosticDetails: String
    public let requiresAlert: Bool
    public init(displayID: UInt32? = nil, error: Error, context: String = "") {
        self.displayID = displayID; self.message = error.localizedDescription
        switch error as? LayoutError {
        case .widthDoesNotFit, .pairDoesNotFit, .tooManyWindows,
             .uncertainGroup, .noEligibleWindows, .visiblePairRequired, .insufficientSpace: requiresAlert = false
        default: requiresAlert = true
        }
        diagnosticDetails = context
    }
}

public struct WindowSizeConstraints: Equatable, Sendable {
    public let minimum: CGSize?
    public let maximum: CGSize?
    public init(minimum: CGSize? = nil, maximum: CGSize? = nil) {
        self.minimum = minimum.flatMap { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 ? $0 : nil }
        self.maximum = maximum.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    }
}

public struct CaptureResult: Sendable {
    public let desktop: DesktopSnapshot
    public let retryableIDs: Set<WindowID>
    public init(desktop: DesktopSnapshot, retryableIDs: Set<WindowID> = []) {
        self.desktop = desktop; self.retryableIDs = retryableIDs
    }
}

public struct LayoutReport: Sendable {
    public var issues: [LayoutIssue] = []
    public var retryableIDs: Set<WindowID> = []
    public init() {}
    public var errors: [LayoutIssue] { issues.filter(\.requiresAlert) }
    public var skipped: [LayoutIssue] { issues.filter { !$0.requiresAlert } }
}

public protocol WindowAccess: AnyObject, Sendable {
    // A scoped capture includes the requested windows and their related group members.
    func capture(only ids: Set<WindowID>?) async throws -> CaptureResult
    func visibility() async throws -> [RenderedWindow]
    func frame(of window: WindowID) async throws -> CGRect
    func resize(_ window: WindowID, to size: CGSize) async throws
    func place(_ window: WindowID, at frame: CGRect) async throws
    func sizeConstraints(of window: WindowID) async -> WindowSizeConstraints
}

public extension WindowAccess {
    func sizeConstraints(of window: WindowID) async -> WindowSizeConstraints { .init() }
    func visibility() async throws -> [RenderedWindow] {
        try await capture(only: nil).desktop.windows.filter(\.isVisible).map {
            RenderedWindow(pid: $0.id.pid, frame: $0.frame)
        }
    }
}

@MainActor public final class LayoutEngine {
    private let access: any WindowAccess
    private let configuration: LayoutConfiguration
    private let pause: @MainActor (UInt64) async throws -> Void
    private let now: @MainActor () -> TimeInterval
    private var groups = WindowGroupTracker()
    private struct CachedLayout {
        let area: CGRect
        let displayID: UInt32
        let frames: [WindowID: CGRect]
        let constraints: [WindowID: WindowSizeConstraints]
        let applications: [WindowID: String]
        let expires: TimeInterval
        let failure: LayoutIssue?
    }
    private var cache: [Set<WindowID>: CachedLayout] = [:]

    public init(access: any WindowAccess, configuration: LayoutConfiguration = .init(),
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                pause: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.access = access; self.configuration = configuration; self.now = now; self.pause = pause
    }

    public func arrangeManually() async -> LayoutReport {
        await arrangeManually(swapVisible: false)
    }

    public func swapVisibleWindows() async -> LayoutReport {
        await arrangeManually(swapVisible: true)
    }

    private func arrangeManually(swapVisible: Bool) async -> LayoutReport {
        var report = LayoutReport()
        var foundPair = false
        do {
            try Task.checkCancellation()
            let (capture, stable) = try await stableDesktop()
            let desktop = capture.desktop
            groups.update(from: desktop, confirmedVisible: stable, pendingIDs: capture.retryableIDs)
            let live = Set(desktop.windows.map(\.id))
            cache = cache.filter { $0.key.isSubset(of: live) }
            report.retryableIDs = swapVisible ? [] : capture.retryableIDs
            for display in desktop.displays {
                try Task.checkCancellation()
                let windows = desktop.windows.filter { Geometry.display(for: $0.frame, in: desktop.displays)?.id == display.id }
                let visible = windows.filter(\.isVisible)
                let visibleIDs = Set(visible.map(\.id))
                let uncertain = !stable || visible.contains { window in
                    guard let group = groups.group(containing: window.id) else { return false }
                    return !group.isComplete || !group.members.isSubset(of: visibleIDs)
                }
                if uncertain, !visible.isEmpty {
                    report.issues.append(LayoutIssue(displayID: display.id, error: LayoutError.uncertainGroup))
                    continue
                }
                if swapVisible {
                    guard visible.count == 2 else {
                        if visible.count > 2 {
                            report.issues.append(LayoutIssue(displayID: display.id, error: LayoutError.tooManyWindows))
                        }
                        continue
                    }
                    foundPair = true
                    if let issue = try await arrangeGroup(visible, on: display.id,
                        in: display.layoutArea(configuration: configuration), state: "visible swap", swap: true) {
                        report.issues.append(issue)
                    }
                    continue
                }
                let area = try display.layoutArea(configuration: configuration)
                if !visible.isEmpty, let issue = try await arrangeGroup(visible, on: display.id, in: area, state: "visible") {
                    report.issues.append(issue); continue
                }
                let hidden = windows.filter { !$0.isVisible }
                let hiddenIDs = Set(hidden.map(\.id))
                var identified: Set<WindowID> = []
                for group in groups.groups where group.members.isSubset(of: hiddenIDs) {
                    identified.formUnion(group.members)
                    guard group.isComplete else {
                        report.issues.append(LayoutIssue(displayID: display.id, error: LayoutError.uncertainGroup)); continue
                    }
                    let members = hidden.filter { group.members.contains($0.id) }
                    if let issue = try await arrangeGroup(members, on: display.id, in: area, state: "hidden") {
                        report.issues.append(issue)
                    }
                }
                if !hiddenIDs.subtracting(identified).isEmpty {
                    report.issues.append(LayoutIssue(displayID: display.id, error: LayoutError.uncertainGroup))
                }
            }
            if swapVisible, !foundPair, report.issues.isEmpty {
                report.issues.append(LayoutIssue(error: LayoutError.visiblePairRequired))
            } else if !swapVisible, !desktop.windows.contains(where: { Geometry.display(for: $0.frame, in: desktop.displays) != nil }) {
                report.issues.append(LayoutIssue(error: LayoutError.noEligibleWindows))
            }
        } catch is CancellationError {} catch { report.issues.append(LayoutIssue(error: error)) }
        return report
    }

    public func arrangeNewWindows(_ ids: Set<WindowID>) async -> LayoutReport {
        var report = LayoutReport()
        do {
            try Task.checkCancellation()
            let capture = try await access.capture(only: ids)
            let desktop = capture.desktop
            report.retryableIDs = capture.retryableIDs.intersection(ids)
            // Keep a new-window batch intact while a possible partner is unreadable.
            // Excluded or closed IDs are absent from both sets and never retried.
            if !capture.retryableIDs.isEmpty {
                report.retryableIDs.formUnion(desktop.windows.map(\.id).filter { ids.contains($0) })
                return report
            }
            groups.update(from: desktop, isCompleteSnapshot: false, pendingIDs: capture.retryableIDs)
            var handled: Set<WindowID> = []
            for window in desktop.windows where ids.contains(window.id) && !handled.contains(window.id) {
                try Task.checkCancellation()
                guard let display = Geometry.display(for: window.frame, in: desktop.displays) else {
                    report.issues.append(LayoutIssue(error: LayoutError.noEligibleWindows)); continue
                }
                var members = [window]
                if let group = groups.group(containing: window.id) {
                    guard group.members.count <= 2 else {
                        handled.formUnion(group.members.intersection(ids))
                        report.issues.append(LayoutIssue(displayID: display.id, error: LayoutError.tooManyWindows)); continue
                    }
                    let related = desktop.windows.filter { group.members.contains($0.id) }
                    guard group.isComplete, related.count == group.members.count else {
                        report.retryableIDs.formUnion(group.members.intersection(ids)); continue
                    }
                    if !window.isVisible {
                        guard group.members.isSubset(of: ids) else {
                            report.issues.append(LayoutIssue(displayID: display.id, error: LayoutError.uncertainGroup)); continue
                        }
                        guard related.count == group.members.count,
                              related.allSatisfy({ $0.isVisible == window.isVisible &&
                                Geometry.display(for: $0.frame, in: desktop.displays)?.id == display.id }) else {
                            report.retryableIDs.formUnion(group.members.intersection(ids)); continue
                        }
                        members = related
                    }
                } else if !window.isVisible {
                    report.retryableIDs.insert(window.id); continue
                }
                handled.formUnion(members.map(\.id))
                if let issue = try await arrangeGroup(members, on: display.id,
                    in: display.layoutArea(configuration: configuration), state: "automatic") {
                    report.issues.append(issue)
                }
            }
            if !desktop.windows.contains(where: { ids.contains($0.id) }), report.retryableIDs.isEmpty {
                report.issues.append(LayoutIssue(error: LayoutError.noEligibleWindows))
            }
        } catch is CancellationError {} catch {
            if (error as? LayoutError) != .accessibilityRequired { report.retryableIDs = ids }
            report.issues.append(LayoutIssue(error: error))
        }
        return report
    }

    private func stableDesktop() async throws -> (CaptureResult, Bool) {
        var capture = try await access.capture(only: nil)
        if capture.desktop.windows.allSatisfy({ !$0.isVisible }) { return (capture, true) }
        let start = now()
        var previous: [RenderedWindow] = []
        var stableReads = 0
        for tick in 0..<7 {
            try Task.checkCancellation()
            let signature = try await access.visibility().sorted {
                let a = [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]
                let b = [$1.frame.minX, $1.frame.minY, $1.frame.width, $1.frame.height]
                return $0.pid == $1.pid ? a.lexicographicallyPrecedes(b) : $0.pid < $1.pid
            }
            stableReads = signature == previous ? stableReads + 1 : 1
            previous = signature
            if now() - start > 1 { break }
            if stableReads >= 3 {
                let fresh = try await access.capture(only: nil)
                let oldVisible = Set(capture.desktop.windows.filter(\.isVisible).map(\.id))
                let newVisible = Set(fresh.desktop.windows.filter(\.isVisible).map(\.id))
                capture = fresh
                if oldVisible == newVisible { return (capture, true) }
                stableReads = 0
            }
            if tick == 6 || now() - start + 0.15 > 1 { break }
            try await pause(150_000_000)
        }
        return (capture, false)
    }

    private func arrangeGroup(_ windows: [WindowSnapshot], on displayID: UInt32,
                              in area: CGRect, state: String, swap: Bool = false) async throws -> LayoutIssue? {
        guard !windows.isEmpty else { return nil }
        try Task.checkCancellation()
        let ids = Set(windows.map(\.id))
        var original: [WindowID: CGRect] = [:]
        var constraints: [WindowID: WindowSizeConstraints] = [:]
        for window in windows {
            do {
                original[window.id] = try await access.frame(of: window.id)
                constraints[window.id] = await access.sizeConstraints(of: window.id)
            } catch is CancellationError { throw CancellationError() }
            catch { return LayoutIssue(displayID: displayID, error: error, context: "group=\(state)") }
        }
        let applications = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.bundleIdentifier ?? "") })
        if !swap, let cached = cache[ids], cached.expires > now(), cached.area == area,
           cached.displayID == displayID, cached.constraints == constraints,
           cached.applications == applications, framesMatch(original, cached.frames) { return cached.failure }
        cache = cache.filter { $0.key.isDisjoint(with: ids) }
        var changed = false
        var details = "display=\(displayID) group=\(state) area=\(area) applications=\(applications.values.sorted())"
        do {
            let (rule, spatial) = try LayoutRule.ordered(windows)
            var plan: [(WindowID, CGRect)]
            if swap, let preserved = swappedAlignedPair(spatial, frames: original, in: area) {
                plan = preserved
                changed = true
            } else {
                let ordered = swap ? Array(spatial.reversed()) : spatial
                let canonical = try? rule.plan(ordered, in: area, gap: configuration.margin, constraints: constraints)
                if let canonical, framesMatch(original, Dictionary(uniqueKeysWithValues: canonical)) { return nil }
                switch rule {
                case .single:
                    plan = try rule.plan(ordered, in: area, gap: configuration.margin, constraints: constraints)
                    changed = true
                    let actual = try await fitForLayout(ordered[0].id, to: plan[0].1)
                    guard actual.width <= area.width + 1, actual.height <= area.height + 1 else { throw LayoutError.rejectedFrame }
                case .pair:
                    _ = try rule.plan(ordered, in: area, gap: configuration.margin, constraints: constraints)
                    changed = true
                    plan = try await measurePair(ordered, in: area, constraints: constraints, details: &details)
                }
            }
            let frames = try await apply(plan, allowSmaller: rule == .single)
            cache[ids] = CachedLayout(area: area, displayID: displayID, frames: frames,
                constraints: constraints, applications: applications, expires: now() + 5, failure: nil)
            return nil
        } catch is CancellationError {
            if changed { try await restore(Array(original)) }
            throw CancellationError()
        } catch {
            if changed {
                do { try await restore(Array(original)) }
                catch { return LayoutIssue(displayID: displayID, error: error, context: details) }
            }
            let issue = LayoutIssue(displayID: displayID, error: error, context: details)
            if !issue.requiresAlert {
                cache[ids] = CachedLayout(area: area, displayID: displayID, frames: original,
                    constraints: constraints, applications: applications, expires: now() + 5, failure: issue)
            }
            return issue
        }
    }

    private func swappedAlignedPair(_ windows: [WindowSnapshot], frames: [WindowID: CGRect],
                                    in area: CGRect) -> [(WindowID, CGRect)]? {
        guard windows.count == 2, let left = frames[windows[0].id], let right = frames[windows[1].id],
              left.isUsable, right.isUsable,
              abs(left.minX - area.minX) <= 1,
              abs(left.minY - area.minY) <= 1, abs(right.minY - area.minY) <= 1,
              abs(right.minX - left.maxX - configuration.margin) <= 1,
              right.maxX <= area.maxX + 1,
              left.height <= area.height + 1, right.height <= area.height + 1 else { return nil }
        return [(windows[1].id, CGRect(origin: area.origin, size: right.size)),
                (windows[0].id, CGRect(x: area.minX + right.width + configuration.margin,
                    y: area.minY, width: left.width, height: left.height))]
    }

    private func measurePair(_ windows: [WindowSnapshot], in area: CGRect,
                             constraints: [WindowID: WindowSizeConstraints], details: inout String) async throws -> [(WindowID, CGRect)] {
        var measured = constraints
        let originalWidths = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame.width) })
        for _ in 0..<3 {
            var plan = try LayoutRule.pair.plan(windows, in: area, gap: configuration.margin, constraints: measured)
            // Check the smaller existing window first. If it reveals a size limit,
            // replan before changing its flexible partner to a provisional size.
            let order = plan.indices.sorted {
                let left = originalWidths[plan[$0].0]!
                let right = originalWidths[plan[$1].0]!
                return left == right ? $0 < $1 : left < right
            }
            var fitted = true
            for slot in order {
                let (id, target) = plan[slot]
                let actual = try await fitForLayout(id, to: target)
                details += " id=\(id.pid):\(id.serial) requested=\(target.size) accepted=\(actual.size)"
                guard actual.height <= target.height + 1 else { throw LayoutError.pairDoesNotFit }
                let old = measured[id] ?? .init()
                var minimum = old.minimum ?? CGSize(width: 1, height: 1)
                var maximum = old.maximum ?? CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
                if actual.width > target.width + 1 {
                    minimum.width = ceil(actual.width); maximum.width = max(maximum.width, minimum.width); fitted = false
                } else if actual.width < target.width - 1 {
                    maximum.width = actual.width; fitted = false
                }
                maximum.height = min(maximum.height, actual.height)
                measured[id] = WindowSizeConstraints(minimum: minimum, maximum: maximum)
                plan[slot].1.size.height = maximum.height
                if !fitted { break }
            }
            if fitted { return plan }
        }
        throw LayoutError.pairDoesNotFit
    }

    private func apply(_ plan: [(WindowID, CGRect)], allowSmaller: Bool) async throws -> [WindowID: CGRect] {
        for _ in 0..<3 {
            try Task.checkCancellation()
            var current: [WindowID: CGRect] = [:]
            for (id, target) in plan {
                let frame = try await access.frame(of: id)
                current[id] = frame
                if !Geometry.near(frame, target) { try await access.place(id, at: target) }
            }
            if framesMatch(current, Dictionary(uniqueKeysWithValues: plan)) { return current }
            var previous: [WindowID: CGRect] = [:]
            var stableReads = 0
            for tick in 1...10 {
                try await pause(50_000_000)
                try Task.checkCancellation()
                var actual: [WindowID: CGRect] = [:]
                for (id, _) in plan { actual[id] = try await access.frame(of: id) }
                if plan.allSatisfy({ id, target in actual[id].map { Geometry.near($0, target) } ?? false }) { return actual }
                stableReads = actual == previous ? stableReads + 1 : 0
                previous = actual
                if allowSmaller, tick >= 8, stableReads >= 2,
                   plan.allSatisfy({ id, target in actual[id].map { Geometry.fits($0, inside: target) } ?? false }) { return actual }
            }
        }
        throw LayoutError.rejectedFrame
    }

    private func framesMatch(_ actual: [WindowID: CGRect], _ expected: [WindowID: CGRect]) -> Bool {
        actual.count == expected.count && actual.allSatisfy { id, frame in expected[id].map { Geometry.near(frame, $0) } ?? false }
    }

    private func fitForLayout(_ id: WindowID, to target: CGRect) async throws -> CGRect {
        try Task.checkCancellation()
        try await access.place(id, at: target)
        let size = target.size
        var actual = try await settledFrame(id, target: size, origin: target.origin)
        if abs(actual.width - size.width) > 1 || abs(actual.height - size.height) > 1 {
            try await access.resize(id, to: CGSize(width: max(1, size.width - 32), height: max(1, size.height - 32)))
            try await access.resize(id, to: size)
            actual = try await settledFrame(id, target: size, origin: target.origin)
            // Preserve the modest retry for apps with sizing increments. If a responsive
            // layout still refuses to shrink, normalize only the refused dimension.
            let resetWidth = size.width > 1 && actual.width > size.width + 1
            let resetHeight = size.height > 1 && actual.height > size.height + 1
            if resetWidth || resetHeight {
                try await access.resize(id, to: CGSize(width: resetWidth ? 1 : size.width,
                                                height: resetHeight ? 1 : size.height))
                try await access.resize(id, to: size)
                actual = try await settledFrame(id, target: size, origin: target.origin)
            }
        }
        return actual
    }

    private func settledFrame(_ id: WindowID, target: CGSize, origin: CGPoint? = nil) async throws -> CGRect {
        var previous: CGRect?
        var stableReads = 0
        var actual = try await access.frame(of: id)
        for tick in 1...10 {
            try await pause(50_000_000)
            try Task.checkCancellation()
            actual = try await access.frame(of: id)
            let sizeMatches = abs(actual.width - target.width) <= 1 && abs(actual.height - target.height) <= 1
            let positionMatches = origin.map { abs(actual.minX - $0.x) <= 1 && abs(actual.minY - $0.y) <= 1 } ?? true
            if sizeMatches && positionMatches { return actual }
            stableReads = actual == previous ? stableReads + 1 : 0
            previous = actual
            if tick >= (origin == nil ? 6 : 8) && stableReads >= 2 { return actual }
        }
        return actual
    }

    private func restore(_ originals: [(WindowID, CGRect)]) async throws {
        let restored = await Task { @MainActor [access, pause] in
            for _ in 0..<3 {
                for (id, frame) in originals { try? await access.place(id, at: frame) }
                try? await pause(150_000_000)
                var matches = true
                for (id, expected) in originals {
                    guard let actual = try? await access.frame(of: id) else { matches = false; continue }
                    if !Geometry.near(actual, expected) { matches = false }
                }
                if matches { return true }
            }
            return false
        }.value
        guard restored else { throw LayoutError.restoreFailed }
    }
}
