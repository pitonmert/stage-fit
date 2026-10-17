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
    public init(id: WindowID, frame: CGRect, isVisible: Bool) {
        self.id = id; self.frame = frame; self.isVisible = isVisible
    }
}

public struct DesktopSnapshot: Sendable {
    public let displays: [Display]
    public let windows: [WindowSnapshot]
    public init(displays: [Display], windows: [WindowSnapshot]) {
        self.displays = displays; self.windows = windows
    }
}

public enum LayoutError: LocalizedError, Equatable {
    case insufficientSpace, pairDoesNotFit, tooManyWindows, rejectedFrame, unavailableWindow
    case accessibilityRequired, unavailableDisplays
    case restoreFailed

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace: return "There is not enough usable space on this display."
        case .pairDoesNotFit: return "These windows cannot fit side by side on this display. Their original layout was restored."
        case .tooManyWindows: return "More than two windows are visible on a display. Leave one or two windows to arrange."
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
    public init(displayID: UInt32? = nil, error: Error) {
        self.displayID = displayID; self.message = error.localizedDescription
    }
}

@MainActor public protocol WindowAccess: AnyObject {
    func capture(only ids: Set<WindowID>?) throws -> DesktopSnapshot
    func frame(of window: WindowID) throws -> CGRect
    func resize(_ window: WindowID, to size: CGSize) throws
    func place(_ window: WindowID, at frame: CGRect) throws
}

@MainActor public final class LayoutEngine {
    private let access: WindowAccess
    private let configuration: LayoutConfiguration
    private let pause: @MainActor (UInt64) async throws -> Void

    public init(access: WindowAccess, configuration: LayoutConfiguration = .init(),
                pause: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.access = access; self.configuration = configuration; self.pause = pause
    }

    public func arrangeManually() async -> [LayoutIssue] {
        let desktop: DesktopSnapshot
        do { try Task.checkCancellation(); desktop = try access.capture(only: nil) }
        catch { return issues(for: error) }
        var issues: [LayoutIssue] = []
        for display in desktop.displays {
            if Task.isCancelled { break }
            let windows = desktop.windows.filter { Geometry.display(for: $0.frame, in: desktop.displays)?.id == display.id }
            let visibleWindows = windows.filter { $0.isVisible }
            let visible = visibleWindows.sorted { left, right in
                if left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
                if left.id.pid != right.id.pid { return left.id.pid < right.id.pid }
                return left.id.serial < right.id.serial
            }
            do {
                guard visible.count <= 2 else { throw LayoutError.tooManyWindows }
                let area = try display.layoutArea(configuration: configuration)
                if visible.count == 2 { try await pair(visible, in: area) }
                else if let window = visible.first { try await single(window.id, in: area) }
                // Hidden groups are changed only after the visible layout succeeds.
                for window in windows where !window.isVisible {
                    do { try await single(window.id, in: area) }
                    catch is CancellationError { throw CancellationError() }
                    catch { issues.append(LayoutIssue(displayID: display.id, error: error)) }
                }
            } catch is CancellationError { break }
            catch { issues.append(LayoutIssue(displayID: display.id, error: error)) }
        }
        return issues
    }

    public func arrangeNewWindows(_ ids: Set<WindowID>) async -> [LayoutIssue] {
        let desktop: DesktopSnapshot
        do { try Task.checkCancellation(); desktop = try access.capture(only: ids) }
        catch { return issues(for: error) }
        var issues: [LayoutIssue] = []
        for window in desktop.windows where ids.contains(window.id) {
            if Task.isCancelled { break }
            guard let display = Geometry.display(for: window.frame, in: desktop.displays) else { continue }
            do { try await single(window.id, in: display.layoutArea(configuration: configuration)) }
            catch is CancellationError { break }
            catch { issues.append(LayoutIssue(displayID: display.id, error: error)) }
        }
        return issues
    }

    private func issues(for error: Error) -> [LayoutIssue] {
        error is CancellationError ? [] : [LayoutIssue(error: error)]
    }

    private func single(_ id: WindowID, in area: CGRect) async throws {
        try Task.checkCancellation()
        let original = try access.frame(of: id)
        do {
            let measured = try await resizeForLayout(id, to: area.size)
            guard measured.width <= area.width + 1, measured.height <= area.height + 1 else {
                throw LayoutError.rejectedFrame
            }
            try access.place(id, at: area)
            let actual = try await settledFrame(id, target: area.size, origin: area.origin)
            guard Geometry.fits(actual, inside: area) else { throw LayoutError.rejectedFrame }
        } catch {
            try await restore([(id, original)], after: error)
        }
    }

    private func pair(_ windows: [WindowSnapshot], in area: CGRect) async throws {
        let ids = windows.map(\.id)
        let originals = try ids.map { ($0, try access.frame(of: $0)) }
        var minimums: [CGFloat] = [1, 1]
        do {
            var targets: [CGRect] = []
            var fitted = false
            for _ in 0..<3 {
                try Task.checkCancellation()
                targets = try Geometry.pair(in: area, gap: configuration.margin,
                                            minimumLeft: minimums[0], minimumRight: minimums[1])
                fitted = true
                // Resize both before moving either: macOS otherwise clamps large windows at the edge.
                for slot in 0..<2 {
                    let actual = try await resizeForLayout(ids[slot], to: targets[slot].size)
                    guard actual.height <= targets[slot].height + 1 else { throw LayoutError.pairDoesNotFit }
                    if actual.width > targets[slot].width + 1 {
                        minimums[slot] = ceil(actual.width); fitted = false
                    }
                }
                if fitted { break }
            }
            guard fitted else { throw LayoutError.pairDoesNotFit }
            for _ in 0..<3 {
                try Task.checkCancellation()
                for slot in 0..<2 { try access.place(ids[slot], at: targets[slot]) }
                try await pause(150_000_000)
                try Task.checkCancellation()
                let actual = try ids.map { try access.frame(of: $0) }
                if zip(actual, targets).allSatisfy({ Geometry.near($0.0, $0.1) }) { return }
            }
            throw LayoutError.rejectedFrame
        } catch {
            try await restore(originals, after: error)
        }
    }

    private func resizeForLayout(_ id: WindowID, to target: CGSize) async throws -> CGRect {
        try Task.checkCancellation()
        try access.resize(id, to: target)
        var actual = try await settledFrame(id, target: target)
        if abs(actual.width - target.width) > 1 || abs(actual.height - target.height) > 1 {
            try access.resize(id, to: CGSize(width: max(1, target.width - 32), height: max(1, target.height - 32)))
            try access.resize(id, to: target)
            actual = try await settledFrame(id, target: target)
        }
        return actual
    }

    private func settledFrame(_ id: WindowID, target: CGSize, origin: CGPoint? = nil) async throws -> CGRect {
        var previous: CGRect?
        var stableReads = 0
        var actual = try access.frame(of: id)
        for tick in 1...10 {
            try await pause(50_000_000)
            try Task.checkCancellation()
            actual = try access.frame(of: id)
            let sizeMatches = abs(actual.width - target.width) <= 1 && abs(actual.height - target.height) <= 1
            let positionMatches = origin.map { abs(actual.minX - $0.x) <= 1 && abs(actual.minY - $0.y) <= 1 } ?? true
            if sizeMatches && positionMatches { return actual }
            stableReads = actual == previous ? stableReads + 1 : 0
            previous = actual
            if tick >= (origin == nil ? 6 : 8) && stableReads >= 2 { return actual }
        }
        return actual
    }

    private func restore(_ originals: [(WindowID, CGRect)], after error: Error) async throws {
        // An unstructured task lets rollback finish even when the placement task was cancelled.
        let restored = await Task { @MainActor [access, pause] in
            for _ in 0..<3 {
                for (id, frame) in originals { try? access.place(id, at: frame) }
                try? await pause(150_000_000)
                let matches = originals.allSatisfy { id, expected in
                    guard let actual = try? access.frame(of: id) else { return false }
                    return Geometry.near(actual, expected)
                }
                if matches { return true }
            }
            return false
        }.value
        guard restored else { throw LayoutError.restoreFailed }
        throw error
    }
}
