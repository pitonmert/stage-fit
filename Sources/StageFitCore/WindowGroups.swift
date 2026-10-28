import Foundation

public struct WindowGroup: Sendable, Equatable {
    public let members: Set<WindowID>
    public let isComplete: Bool

    public init(members: Set<WindowID>, isComplete: Bool = true) {
        self.members = members; self.isComplete = isComplete
    }
}

// Uses observed membership, never window titles, application names or similar sizes.
struct WindowGroupTracker {
    private(set) var groups: [WindowGroup] = []

    mutating func update(from desktop: DesktopSnapshot, confirmedVisible: Bool = false, isCompleteSnapshot: Bool = true, pendingIDs: Set<WindowID> = []) {
        let live = Set(desktop.windows.map(\.id)).union(pendingIDs)
        if isCompleteSnapshot { groups.removeAll { !$0.members.isSubset(of: live) } }

        // Native strip membership supersedes observations from a previously active group.
        // Overlapping strip entries can occur during transitions; protect their union.
        var native: [WindowGroup] = []
        for group in desktop.hiddenGroups where !group.members.isEmpty {
            let conflicts = native.filter { !$0.members.isDisjoint(with: group.members) }
            let members = conflicts.reduce(group.members) { $0.union($1.members) }
            let complete = group.isComplete && conflicts.allSatisfy {
                $0.isComplete && $0.members == group.members
            }
            native.removeAll { !$0.members.isDisjoint(with: members) }
            native.append(WindowGroup(members: members, isComplete: complete))
        }
        for group in native {
            groups.removeAll { !$0.members.isDisjoint(with: group.members) }
            groups.append(group)
        }

        for display in desktop.displays {
            let visible = Set(desktop.windows.filter {
                $0.isVisible && Geometry.display(for: $0.frame, in: desktop.displays)?.id == display.id
            }.map(\.id))
            guard !visible.isEmpty else { continue }
            // A partial reveal is not evidence that a known group has split.
            guard !native.contains(where: {
                !$0.members.isDisjoint(with: visible) &&
                (!$0.members.isSubset(of: visible) || !$0.isComplete)
            }) else { continue }
            guard !groups.contains(where: {
                !$0.members.isDisjoint(with: visible) && !$0.members.isDisjoint(with: pendingIDs)
            }) else { continue }
            if !confirmedVisible, visible.count == 1, groups.contains(where: {
                !$0.members.isDisjoint(with: visible) && !$0.members.isSubset(of: visible)
            }) { continue }
            groups.removeAll { !$0.members.isDisjoint(with: visible) }
            groups.append(WindowGroup(members: visible))
        }
    }

    func group(containing id: WindowID) -> WindowGroup? {
        groups.first { $0.members.contains(id) }
    }
}

public struct ServerWindow: Sendable {
    public let number: UInt32
    public let pid: Int32
    public let frame: CGRect

    public init(number: UInt32, pid: Int32, frame: CGRect) {
        self.number = number; self.pid = pid; self.frame = frame
    }
}

public enum StageGroupResolver {
    // Only unique PID/frame matches are safe when AX does not expose a window number.
    public static func resolve(_ groups: [[UInt32]], windows: [WindowSnapshot],
                               serverWindows: [ServerWindow],
                               numbers: [WindowID: UInt32] = [:],
                               ignoredNumbers: Set<UInt32> = []) -> [WindowGroup] {
        var candidates: [UInt32: Set<WindowID>] = [:]
        for window in windows {
            if let number = numbers[window.id] {
                candidates[number, default: []].insert(window.id)
            } else {
                let matches = serverWindows.filter {
                    $0.pid == window.id.pid && Geometry.near($0.frame, window.frame)
                }
                if matches.count == 1 {
                    candidates[matches[0].number, default: []].insert(window.id)
                }
            }
        }
        return groups.compactMap { raw in
            let ids = Set(raw).subtracting(ignoredNumbers)
            var members: Set<WindowID> = []
            var complete = !ids.isEmpty
            for number in ids {
                let matches = candidates[number] ?? []
                members.formUnion(matches)
                if matches.count != 1 { complete = false }
            }
            guard !members.isEmpty else { return nil }
            return WindowGroup(members: members, isComplete: complete)
        }
    }
}

// Chooses AX application reads from fresh group/Quartz metadata, before enumerating AXWindows.
public struct WindowCaptureSelection: Sendable {
    public let pids: Set<Int32>
    public let numbers: Set<UInt32>

    public init(requested: Set<WindowID>, frames: [WindowID: CGRect],
                numbers windowNumbers: [WindowID: UInt32], groups: [[UInt32]],
                server: [ServerWindow], rendered: [RenderedWindow], displays: [Display]) {
        let requestedNumbers = Set(requested.compactMap { windowNumbers[$0] })
        let memberNumbers: Set<UInt32> = groups.filter { !Set($0).isDisjoint(with: requestedNumbers) }
            .reduce(into: []) { $0.formUnion($1) }
        numbers = memberNumbers
        var selected = Set(requested.map(\.pid))
        if !memberNumbers.isEmpty {
            selected.formUnion(server.filter { memberNumbers.contains($0.number) }.map(\.pid))
        } else {
            let targetDisplays = Set(frames.values.compactMap { Geometry.display(for: $0, in: displays)?.id })
            selected.formUnion(rendered.filter {
                Geometry.display(for: $0.frame, in: displays).map { targetDisplays.contains($0.id) } == true
            }.map(\.pid))
        }
        pids = selected
    }
}
