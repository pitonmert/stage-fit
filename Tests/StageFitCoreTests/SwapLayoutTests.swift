import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class SwapLayoutTests: XCTestCase {
    let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1320))
    let left = WindowID(pid: 1, serial: 1)
    let right = WindowID(pid: 2, serial: 2)
    let hidden = WindowID(pid: 3, serial: 3)

    func fixture(aligned: Bool = true) -> FakeWindows {
        let windows = FakeWindows(displays: [display], frames: [
            left: aligned ? CGRect(x: 199, y: 39, width: 740, height: 1000)
                : CGRect(x: 300, y: 100, width: 740, height: 800),
            right: aligned ? CGRect(x: 948, y: 39, width: 1603, height: 1302)
                : CGRect(x: 1100, y: 140, width: 1100, height: 900),
            hidden: CGRect(x: 300, y: 100, width: 900, height: 700)
        ], visible: [left, right])
        windows.maximums[left] = CGSize(width: 740, height: 1000)
        windows.hiddenGroups = [WindowGroup(members: [hidden])]
        return windows
    }

    func engine(_ windows: FakeWindows) -> LayoutEngine { LayoutEngine(access: windows, pause: { _ in }) }

    func assertHiddenUntouched(_ windows: FakeWindows, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden], file: file, line: line)
        XCTAssertFalse(windows.resizes.contains(hidden), file: file, line: line)
        XCTAssertFalse(windows.places.contains { $0.0 == hidden }, file: file, line: line)
    }

    func testAlignedPairKeepsOwnWidthsAndHeightsAndOnlySwapsPositions() async {
        let windows = fixture()
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(windows.frames[right], CGRect(x: 199, y: 39, width: 1603, height: 1302))
        XCTAssertEqual(windows.frames[left], CGRect(x: 1811, y: 39, width: 740, height: 1000))
        for (id, requested) in windows.resizeRequests {
            XCTAssertEqual(requested, windows.originals[id]?.size)
        }
        assertHiddenUntouched(windows)
    }

    func testSecondSwapRestoresOriginalOrderEvenWithinCacheLifetime() async {
        let windows = fixture()
        let worker = engine(windows)
        let first = await worker.swapVisibleWindows()
        let second = await worker.swapVisibleWindows()
        XCTAssertTrue(first.issues.isEmpty); XCTAssertTrue(second.issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
        assertHiddenUntouched(windows)
    }

    func testUnalignedPairGetsOnlyReversedStandardTargets() async {
        let windows = fixture(aligned: false)
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertTrue(report.issues.isEmpty)
        let expected: [WindowID: CGRect] = [
            right: CGRect(x: 199, y: 39, width: 1603, height: 1302),
            left: CGRect(x: 1811, y: 39, width: 740, height: 1000)
        ]
        XCTAssertEqual(windows.places.count, 2)
        for (id, target) in windows.places { XCTAssertEqual(target, expected[id]) }
        for (id, target) in expected { XCTAssertEqual(windows.frames[id], target) }
        assertHiddenUntouched(windows)
    }

    func testFreshNormalArrangementPreservesSwappedOrderWithoutStoredPreference() async {
        let windows = fixture()
        let swapped = await engine(windows).swapVisibleWindows()
        XCTAssertTrue(swapped.issues.isEmpty)
        let frames = windows.frames
        windows.resizes.removeAll(); windows.places.removeAll()
        // A fresh engine has no cache or saved ordering preference.
        let normal = await engine(windows).arrangeManually()
        XCTAssertTrue(normal.issues.isEmpty)
        XCTAssertEqual(windows.frames[left], frames[left])
        XCTAssertEqual(windows.frames[right], frames[right])
        XCTAssertFalse(windows.resizes.contains(left)); XCTAssertFalse(windows.resizes.contains(right))
    }

    func testNormalArrangementCacheDoesNotSuppressSwap() async {
        let windows = fixture()
        let worker = engine(windows)
        let normal = await worker.arrangeManually()
        XCTAssertTrue(normal.issues.isEmpty)
        let report = await worker.swapVisibleWindows()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertLessThan(windows.frames[right]!.minX, windows.frames[left]!.minX)
    }

    func testAlignedCappedPairWithUnusedWidthKeepsSizes() async {
        let windows = fixture()
        windows.frames[left] = CGRect(x: 199, y: 39, width: 650, height: 800)
        windows.frames[right] = CGRect(x: 858, y: 39, width: 600, height: 700)
        windows.maximums[left] = CGSize(width: 650, height: 800)
        windows.maximums[right] = CGSize(width: 600, height: 700)
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(windows.frames[right], CGRect(x: 199, y: 39, width: 600, height: 700))
        XCTAssertEqual(windows.frames[left], CGRect(x: 808, y: 39, width: 650, height: 800))
        assertHiddenUntouched(windows)
    }

    func testNoPairOrThreeVisibleWindowsLeavesEveryWindowUntouched() async {
        for visible: Set<WindowID> in [[], [left], [left, right, hidden]] {
            let windows = fixture()
            windows.visible = visible
            let report = await engine(windows).swapVisibleWindows()
            let expected: LayoutError = visible.count > 2 ? .tooManyWindows : .visiblePairRequired
            XCTAssertEqual(report.skipped.first?.message, expected.localizedDescription)
            XCTAssertTrue(report.errors.isEmpty)
            XCTAssertEqual(windows.frames, windows.originals)
            XCTAssertTrue(windows.resizes.isEmpty); XCTAssertTrue(windows.places.isEmpty)
        }
    }

    func testHiddenPairIsNeverSwappedOrResized() async {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left, right])]
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertEqual(report.skipped.first?.message, LayoutError.visiblePairRequired.localizedDescription)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty); XCTAssertTrue(windows.places.isEmpty)
    }

    func testIncompleteVisibleMembershipIsPreserved() async {
        let windows = fixture()
        windows.hiddenGroups = [WindowGroup(members: [left, right], isComplete: false)]
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertEqual(report.skipped.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testOneVisibleWindowOnEachDisplayIsNotACrossDisplayPair() async {
        let windows = fixture()
        windows.displays.append(Display(id: 2, frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 2560, y: 30, width: 2560, height: 1320)))
        windows.frames[right]?.origin.x = 3000
        let original = windows.frames
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertEqual(report.skipped.first?.message, LayoutError.visiblePairRequired.localizedDescription)
        XCTAssertEqual(windows.frames, original)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testKnownImpossibleUnalignedPairFailsBeforeAnyWrites() async {
        let windows = fixture(aligned: false)
        windows.minimums[left] = CGSize(width: 1200, height: 700)
        windows.minimums[right] = CGSize(width: 1200, height: 700)
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertEqual(report.skipped.first?.message,
            LayoutError.widthDoesNotFit(required: 2409, available: 2352).localizedDescription)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty); XCTAssertTrue(windows.places.isEmpty)
    }

    func testPlacementFailureRestoresBothAndPreservesHiddenWindow() async {
        let windows = fixture()
        windows.failNextPlacement = left
        let report = await engine(windows).swapVisibleWindows()
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
        assertHiddenUntouched(windows)
    }

    func testCancellationRollsBackSwap() async {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in
            if !windows.places.isEmpty { throw CancellationError() }
        })
        let report = await worker.swapVisibleWindows()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
        assertHiddenUntouched(windows)
    }
}
