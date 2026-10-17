import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class FakeWindows: WindowAccess {
    let displays: [Display]
    let originals: [WindowID: CGRect]
    var frames: [WindowID: CGRect]
    var visible: Set<WindowID>
    var minimums: [WindowID: CGSize] = [:]
    var places: [(WindowID, CGRect)] = []
    var resizes: [WindowID] = []
    var failNextPlacement: WindowID?
    var rejectOrigins: Set<WindowID> = []
    var delayedReadbacks = 0
    var stale: [WindowID: (CGRect, Int)] = [:]
    var onPlace: (() -> Void)?
    var captureError: Error?
    var failRestoration: Set<WindowID> = []

    init(displays: [Display], frames: [WindowID: CGRect], visible: Set<WindowID>) {
        self.displays = displays; self.frames = frames; originals = frames; self.visible = visible
    }
    func capture(only ids: Set<WindowID>?) throws -> DesktopSnapshot {
        if let captureError { throw captureError }
        return DesktopSnapshot(displays: displays, windows: frames.compactMap { id, frame in
            guard ids?.contains(id) != false else { return nil }
            return WindowSnapshot(id: id, frame: frame, isVisible: visible.contains(id))
        })
    }
    func frame(of id: WindowID) throws -> CGRect {
        if let (old, count) = stale[id], count > 0 { stale[id] = (old, count - 1); return old }
        guard let frame = frames[id] else { throw LayoutError.unavailableWindow }
        return frame
    }
    func resize(_ id: WindowID, to size: CGSize) throws {
        guard var frame = frames[id] else { throw LayoutError.unavailableWindow }
        resizes.append(id)
        if delayedReadbacks > 0 { stale[id] = (frame, delayedReadbacks) }
        let minimum = minimums[id] ?? .zero
        frame.size = CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
        frames[id] = frame
    }
    func place(_ id: WindowID, at target: CGRect) throws {
        if failRestoration.contains(id), target == originals[id] { throw LayoutError.unavailableWindow }
        if failNextPlacement == id { failNextPlacement = nil; throw LayoutError.unavailableWindow }
        places.append((id, target))
        try resize(id, to: target.size)
        if rejectOrigins.contains(id), target != originals[id] {
            frames[id]?.origin = CGPoint(x: target.minX + 30, y: target.minY)
        } else { frames[id]?.origin = target.origin }
        onPlace?()
    }
}

@MainActor final class LayoutEngineTests: XCTestCase {
    let primaryDisplay = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                          visibleFrame: CGRect(x: 0, y: 33, width: 1728, height: 994), stageExtent: 161)
    let upperDisplay = Display(id: 2, frame: CGRect(x: -422, y: -1440, width: 2560, height: 1440),
                      visibleFrame: CGRect(x: -422, y: -1410, width: 2560, height: 1410), stageExtent: 181)
    let left = WindowID(pid: 10, serial: 1)
    let right = WindowID(pid: 20, serial: 2)
    let hidden = WindowID(pid: 30, serial: 3)

    func fixture(extraDisplay: Bool = false) -> FakeWindows {
        FakeWindows(displays: extraDisplay ? [primaryDisplay, upperDisplay] : [primaryDisplay], frames: [
            left: CGRect(x: 250, y: 180, width: 1100, height: 750),
            right: CGRect(x: 500, y: 210, width: 900, height: 700),
            hidden: CGRect(x: 300, y: 150, width: 800, height: 650)
        ], visible: [left, right])
    }
    func engine(_ windows: FakeWindows) -> LayoutEngine { LayoutEngine(access: windows, pause: { _ in }) }

    func testEqualPairThenHiddenGroupMaximize() async throws {
        let windows = fixture()
        let issues = await engine(windows).arrangeManually()
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        let expected = try Geometry.pair(in: area, gap: 9)
        XCTAssertEqual(windows.frames[left], expected[0]); XCTAssertEqual(windows.frames[right], expected[1])
        XCTAssertEqual(windows.frames[hidden], area)
        XCTAssertEqual(windows.places.last?.0, hidden)
    }

    func testVisibleOrderIsSpatialRatherThanProcessEnumeration() async throws {
        let windows = fixture()
        windows.frames[left]?.origin.x = 900
        windows.frames[right]?.origin.x = 100
        let issues = await engine(windows).arrangeManually()
        XCTAssertTrue(issues.isEmpty)
        XCTAssertLessThan(windows.frames[right]!.minX, windows.frames[left]!.minX)
    }

    func testUnequalMinimumWidthsShareRemainingSpace() async throws {
        let windows = fixture()
        windows.minimums[left] = CGSize(width: 980, height: 600)
        windows.minimums[right] = CGSize(width: 560, height: 400)
        let issues = await engine(windows).arrangeManually()
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[left]?.width, 980)
        XCTAssertEqual(windows.frames[right]?.width, 560)
        XCTAssertEqual(windows.frames[right]!.minX - windows.frames[left]!.maxX, 9)
    }

    func testImpossiblePairRestoresBothAndPreservesHiddenWindows() async {
        let windows = fixture()
        windows.minimums[left] = CGSize(width: 980, height: 600)
        windows.minimums[right] = CGSize(width: 611, height: 400)
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertFalse(windows.places.contains { $0.0 == hidden })
    }

    func testMinimumHeightFailureRestoresBoth() async {
        let windows = fixture()
        windows.minimums[right] = CGSize(width: 200, height: 1100)
        // Original is feasible for the application's own minimum.
        windows.frames[right]?.size.height = 1100
        let before = windows.frames
        let issues = await engine(windows).arrangeManually()
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(windows.frames, before)
    }

    func testPlacementFailureRestoresPartiallyChangedPair() async {
        let windows = fixture()
        windows.failNextPlacement = right
        let issues = await engine(windows).arrangeManually()
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
    }

    func testRejectedCoordinatesRestoreBothAndPreserveHidden() async {
        let windows = fixture()
        windows.rejectOrigins = [right]
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
    }

    func testStaleReadbacksDoNotBecomeMinimumWidths() async {
        let windows = fixture()
        windows.delayedReadbacks = 3
        let issues = await engine(windows).arrangeManually()
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[left]?.width, 770)
        XCTAssertEqual(windows.frames[right]?.width, 770)
    }

    func testThreeVisibleWindowsCauseNoChanges() async {
        let windows = fixture()
        windows.visible.insert(hidden)
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.places.isEmpty); XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testNoVisibleWindowsStillResizesHiddenGroups() async throws {
        let windows = fixture()
        windows.visible.removeAll()
        let issues = await engine(windows).arrangeManually()
        XCTAssertTrue(issues.isEmpty)
        XCTAssertTrue(windows.frames.values.allSatisfy { $0 == (try? primaryDisplay.layoutArea()) })
    }

    func testAutomaticResizesOnlyRequestedNewWindow() async throws {
        let windows = fixture()
        let issues = await engine(windows).arrangeNewWindows([right])
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[right], try primaryDisplay.layoutArea())
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden])
    }

    func testAutomaticMinimumFailureRestoresOnlyNewWindow() async {
        let windows = fixture()
        windows.minimums[right] = CGSize(width: 1700, height: 500)
        windows.frames[right]?.size.width = 1700
        let before = windows.frames
        let issues = await engine(windows).arrangeNewWindows([right])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, before)
    }

    func testFailureOnOneDisplayDoesNotAffectAnotherOrMovePairThere() async throws {
        let windows = fixture(extraDisplay: true)
        let upper = WindowID(pid: 40, serial: 4)
        windows.frames[upper] = CGRect(x: -100, y: -1200, width: 1000, height: 800)
        windows.visible.insert(upper)
        windows.minimums[left] = CGSize(width: 980, height: 600)
        windows.minimums[right] = CGSize(width: 611, height: 400)
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[right], windows.originals[right])
        XCTAssertEqual(windows.frames[upper], try upperDisplay.layoutArea())
    }

    func testCancellationAfterPlacementRollsBackBeforeReturning() async {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in throw CancellationError() })
        let issues = await worker.arrangeNewWindows([right])
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
    }

    func testWindowClosingDuringPlacementRestoresSurvivingWindow() async {
        let windows = fixture()
        windows.onPlace = { windows.frames.removeValue(forKey: self.right) }
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden])
        windows.onPlace = nil
    }

    func testRestorationFailureIsReportedRatherThanClaimingSuccess() async {
        let windows = fixture()
        windows.rejectOrigins = [right]
        windows.failRestoration = [right]
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.first?.message, LayoutError.restoreFailed.localizedDescription)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden])
    }

    func testCapturePermissionFailureDoesNotModifyAnyWindow() async {
        let windows = fixture()
        windows.captureError = LayoutError.accessibilityRequired
        let issues = await engine(windows).arrangeManually()
        XCTAssertEqual(issues.first?.message, LayoutError.accessibilityRequired.localizedDescription)
        XCTAssertTrue(windows.resizes.isEmpty)
        XCTAssertTrue(windows.places.isEmpty)
    }

    func testCancellationDuringPairProbeRestoresBothWindows() async {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in throw CancellationError() })
        let issues = await worker.arrangeManually()
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
    }

}
