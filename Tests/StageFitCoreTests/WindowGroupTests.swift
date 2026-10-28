import CoreGraphics
import XCTest
@testable import StageFitCore

final class WindowGroupTests: XCTestCase {
    let a = WindowID(pid: 10, serial: 1)
    let b = WindowID(pid: 10, serial: 2)
    let c = WindowID(pid: 20, serial: 3)
    let frame = CGRect(x: 200, y: 100, width: 800, height: 600)

    func testNativeNumbersResolveSameAppWindowsEvenWithIdenticalFrames() {
        let windows = [a, b].map { WindowSnapshot(id: $0, frame: frame, isVisible: false) }
        let result = StageGroupResolver.resolve([[100, 101]], windows: windows,
            serverWindows: [], numbers: [a: 100, b: 101])
        XCTAssertEqual(result, [WindowGroup(members: [a, b])])
    }

    func testUniqueGeometryFallbackMatchesByPIDAndFrame() {
        let otherFrame = frame.offsetBy(dx: 300, dy: 0)
        let windows = [WindowSnapshot(id: a, frame: frame, isVisible: false),
                       WindowSnapshot(id: b, frame: otherFrame, isVisible: false)]
        let server = [ServerWindow(number: 100, pid: a.pid, frame: frame),
                      ServerWindow(number: 101, pid: b.pid, frame: otherFrame),
                      ServerWindow(number: 102, pid: c.pid, frame: frame)]
        XCTAssertEqual(StageGroupResolver.resolve([[100, 101]], windows: windows, serverWindows: server),
                       [WindowGroup(members: [a, b])])
    }

    func testAmbiguousGeometryCannotTurnPairIntoKnownSingle() {
        let windows = [a, b].map { WindowSnapshot(id: $0, frame: frame, isVisible: false) }
        let server = [ServerWindow(number: 100, pid: a.pid, frame: frame)]
        let result = StageGroupResolver.resolve([[100]], windows: windows, serverWindows: server)
        XCTAssertEqual(result, [WindowGroup(members: [a, b], isComplete: false)])
    }

    func testMissingMemberProtectsKnownMember() {
        let windows = [WindowSnapshot(id: a, frame: frame, isVisible: false)]
        let result = StageGroupResolver.resolve([[100, 101]], windows: windows,
            serverWindows: [], numbers: [a: 100])
        XCTAssertEqual(result, [WindowGroup(members: [a], isComplete: false)])
    }

    func testWindowManagerThumbnailIDsDoNotCountAsApplicationMembers() {
        let windows = [WindowSnapshot(id: a, frame: frame, isVisible: false)]
        let result = StageGroupResolver.resolve([[100, 900]], windows: windows,
            serverWindows: [], numbers: [a: 100], ignoredNumbers: [900])
        XCTAssertEqual(result, [WindowGroup(members: [a])])
    }

    func testConflictingNativeGroupsAreProtectedAsOneIncompleteGroup() {
        var tracker = WindowGroupTracker()
        let windows = [a, b, c].map { WindowSnapshot(id: $0, frame: frame, isVisible: false) }
        tracker.update(from: DesktopSnapshot(displays: [], windows: windows,
            hiddenGroups: [WindowGroup(members: [a, b]), WindowGroup(members: [b, c])]))
        XCTAssertEqual(tracker.groups, [WindowGroup(members: [a, b, c], isComplete: false)])
    }

    func testDuplicateNativeGroupsAreProcessedOnlyOnce() {
        var tracker = WindowGroupTracker()
        let windows = [a, b].map { WindowSnapshot(id: $0, frame: frame, isVisible: false) }
        let group = WindowGroup(members: [a, b])
        tracker.update(from: DesktopSnapshot(displays: [], windows: windows, hiddenGroups: [group, group]))
        XCTAssertEqual(tracker.groups, [group])
    }
}
