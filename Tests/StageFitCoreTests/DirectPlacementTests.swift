import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class DirectPlacementTests: XCTestCase {
    let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1320))
    let capped = WindowID(pid: 1, serial: 1)
    let flexible = WindowID(pid: 2, serial: 2)

    func fixture(cappedOnRight: Bool = false) -> FakeWindows {
        let windows = FakeWindows(displays: [display], frames: [
            capped: CGRect(x: cappedOnRight ? 1700 : 199, y: 39, width: 740, height: 1302),
            flexible: CGRect(x: cappedOnRight ? 199 : 948, y: 39, width: 1603, height: 1302)
        ], visible: [capped, flexible])
        windows.exposesConstraints = false
        windows.maximums[capped] = CGSize(width: 740, height: CGFloat.infinity)
        windows.rightEdges[flexible] = 2551
        return windows
    }

    func assertDirectFlexiblePlacement(_ windows: FakeWindows, onLeft: Bool = false,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let target = CGRect(x: onLeft ? 199 : 948, y: 39, width: 1603, height: 1302)
        let requests = windows.resizeRequests.filter { $0.0 == flexible }
        XCTAssertFalse(requests.isEmpty, file: file, line: line)
        XCTAssertTrue(requests.allSatisfy { $0.1 == target.size }, file: file, line: line)
        let placements = windows.places.filter { $0.0 == flexible }
        XCTAssertEqual(placements.count, 1, file: file, line: line)
        XCTAssertEqual(placements.first?.1, target, file: file, line: line)
        XCTAssertEqual(windows.frames[flexible], target, file: file, line: line)
    }

    func testCappedLeftWindowDoesNotShrinkFlexiblePartnerToHalfWidthFirst() async {
        let windows = fixture()
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertTrue(report.issues.isEmpty)
        assertDirectFlexiblePlacement(windows)
    }

    func testCappedRightWindowIsMeasuredBeforeFlexiblePartnerAndKeepsRight() async {
        let windows = fixture(cappedOnRight: true)
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertTrue(report.issues.isEmpty)
        assertDirectFlexiblePlacement(windows, onLeft: true)
        XCTAssertEqual(windows.frames[capped]?.minX, 1811)
    }

    func testReportedLimitsOnlyReceiveFinalFrameRequests() async {
        let windows = fixture()
        windows.exposesConstraints = true
        windows.maximums[capped] = CGSize(width: 740, height: 900)
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertTrue(report.issues.isEmpty)
        for (id, requested) in windows.resizeRequests {
            XCTAssertEqual(requested, windows.frames[id]?.size)
        }
        XCTAssertEqual(windows.places.count, 2)
    }

    func testSingleMovesToFinalOriginBeforeGrowingAgainstScreenEdge() async throws {
        let windows = FakeWindows(displays: [display], frames: [
            flexible: CGRect(x: 1200, y: 100, width: 1000, height: 900)
        ], visible: [flexible])
        windows.rightEdges[flexible] = 2551
        let target = try display.layoutArea()
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(windows.frames[flexible], target)
        XCTAssertEqual(windows.resizeRequests.count, 1)
        XCTAssertEqual(windows.resizeRequests.first?.1, target.size)
        XCTAssertEqual(windows.places.count, 1)
    }
}
