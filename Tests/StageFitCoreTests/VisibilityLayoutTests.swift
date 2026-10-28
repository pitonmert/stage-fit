import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class VisibilityLayoutTests: XCTestCase {
    let single = WindowID(pid: 1, serial: 1)
    let left = WindowID(pid: 2, serial: 2)
    let right = WindowID(pid: 3, serial: 3)

    func display(extent: CGFloat) -> Display {
        Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1320), stageExtent: extent)
    }

    func fixture(singleVisible: Bool) -> FakeWindows {
        let windows = FakeWindows(displays: [display(extent: singleVisible ? 151 : 183)], frames: [
            single: CGRect(x: 300, y: 100, width: 1800, height: 1000),
            left: CGRect(x: 300, y: 100, width: 900, height: 1000),
            right: CGRect(x: 1300, y: 100, width: 900, height: 1000)
        ], visible: singleVisible ? [single] : [left, right])
        windows.hiddenGroups = singleVisible
            ? [WindowGroup(members: [left, right])]
            : [WindowGroup(members: [single])]
        return windows
    }

    func testSwitchingForegroundGroupDoesNotResizeOrMoveArrangedWindows() async {
        let windows = fixture(singleVisible: false)
        let engine = LayoutEngine(access: windows, pause: { _ in })
        let first = await engine.arrangeManually()
        XCTAssertTrue(first.issues.isEmpty)
        let arranged = windows.frames
        windows.resizes.removeAll(); windows.places.removeAll()
        for singleVisible in [true, false, true] {
            windows.visible = singleVisible ? [single] : [left, right]
            windows.displays = [display(extent: singleVisible ? 151 : 183)]
            windows.hiddenGroups = singleVisible
                ? [WindowGroup(members: [left, right])]
                : [WindowGroup(members: [single])]
            let report = await engine.arrangeManually()
            XCTAssertTrue(report.issues.isEmpty)
            XCTAssertEqual(windows.frames, arranged)
            XCTAssertTrue(windows.resizes.isEmpty); XCTAssertTrue(windows.places.isEmpty)
        }
    }

    func testFreshForegroundAndBackgroundLayoutsProduceIdenticalFrames() async {
        var results: [[WindowID: CGRect]] = []
        for singleVisible in [false, true] {
            let windows = fixture(singleVisible: singleVisible)
            let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
            XCTAssertTrue(report.issues.isEmpty)
            results.append(windows.frames)
        }
        XCTAssertEqual(results[0], results[1])
    }

    func testAutomaticNewSingleHasSameFrameWhetherVisibleOrHidden() async throws {
        let expected = try display(extent: 0).layoutArea()
        for singleVisible in [false, true] {
            let windows = fixture(singleVisible: singleVisible)
            let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeNewWindows([single])
            XCTAssertTrue(report.issues.isEmpty)
            XCTAssertEqual(windows.frames[single], expected)
            XCTAssertEqual(windows.frames[left], windows.originals[left])
            XCTAssertEqual(windows.frames[right], windows.originals[right])
        }
    }
}
