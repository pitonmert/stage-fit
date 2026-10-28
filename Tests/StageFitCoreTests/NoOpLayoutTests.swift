import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class NoOpLayoutTests: XCTestCase {
    let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1100),
        visibleFrame: CGRect(x: 0, y: 30, width: 1800, height: 1030), stageExtent: 160)
    let a = WindowID(pid: 10, serial: 1)
    let b = WindowID(pid: 20, serial: 2)
    let c = WindowID(pid: 30, serial: 3)

    func engine(_ windows: FakeWindows) -> LayoutEngine { LayoutEngine(access: windows, pause: { _ in }) }

    func clearWrites(_ windows: FakeWindows) {
        windows.resizes.removeAll(); windows.places.removeAll()
    }

    func assertNoWrites(_ windows: FakeWindows, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(windows.resizes.isEmpty, file: file, line: line)
        XCTAssertTrue(windows.places.isEmpty, file: file, line: line)
    }

    func pairFixture() -> FakeWindows {
        FakeWindows(displays: [display], frames: [
            a: CGRect(x: 220, y: 100, width: 900, height: 700),
            b: CGRect(x: 500, y: 180, width: 800, height: 650)
        ], visible: [a, b])
    }

    func testAlreadyFilledSingleRequiresNoWritesOnFirstTrigger() async throws {
        let area = try display.layoutArea()
        let windows = FakeWindows(displays: [display], frames: [a: area], visible: [a])
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty); assertNoWrites(windows)
    }

    func testAlreadyCorrectPairRequiresNoWritesOnFirstTrigger() async throws {
        let targets = try Geometry.pair(in: display.layoutArea(), gap: 9)
        let windows = FakeWindows(displays: [display], frames: [a: targets[0], b: targets[1]], visible: [a, b])
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty); assertNoWrites(windows)
    }

    func testCorrectPairWithUnequalMinimumWidthsRequiresNoProbing() async throws {
        let area = try display.layoutArea()
        let targets = try Geometry.pair(in: area, gap: 9, minimumLeft: 300, minimumRight: 1000)
        let windows = FakeWindows(displays: [display], frames: [a: targets[0], b: targets[1]], visible: [a, b])
        windows.minimums = [a: CGSize(width: 300, height: 300), b: CGSize(width: 1000, height: 600)]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty); assertNoWrites(windows)
    }

    func testCorrectSingleWithReportedMaximumSizeRequiresNoProbing() async throws {
        let area = try display.layoutArea()
        let target = CGRect(origin: area.origin, size: CGSize(width: 700, height: 800))
        let windows = FakeWindows(displays: [display], frames: [a: target], visible: [a])
        windows.maximums[a] = target.size
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty); assertNoWrites(windows)
    }

    func testUnreportedSingleSizeLimitIsRememberedAfterSuccessfulLayout() async {
        let windows = FakeWindows(displays: [display], frames: [a: CGRect(x: 300, y: 100, width: 650, height: 700)], visible: [a])
        windows.exposesConstraints = false
        windows.maximums[a] = CGSize(width: 700, height: 800)
        let worker = engine(windows)
        let first = await worker.arrangeManually().issues
        XCTAssertTrue(first.isEmpty)
        clearWrites(windows)
        let second = await worker.arrangeManually().issues
        XCTAssertTrue(second.isEmpty); assertNoWrites(windows)
    }

    func testUnreportedPairConstraintsAreRememberedAcrossRepeatedTriggers() async {
        let windows = pairFixture()
        windows.exposesConstraints = false
        windows.maximums[a] = CGSize(width: 700, height: 800)
        let worker = engine(windows)
        let first = await worker.arrangeManually().issues
        XCTAssertTrue(first.isEmpty)
        let arranged = windows.frames
        clearWrites(windows)
        for _ in 0..<50 {
            let issues = await worker.arrangeManually().issues
            XCTAssertTrue(issues.isEmpty)
        }
        XCTAssertEqual(windows.frames, arranged); assertNoWrites(windows)
    }

    func testMovingOneCachedWindowCausesRepair() async {
        let windows = pairFixture()
        let worker = engine(windows)
        let first = await worker.arrangeManually().issues
        XCTAssertTrue(first.isEmpty)
        let arranged = windows.frames
        windows.frames[a]?.origin.y += 30
        clearWrites(windows)
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertFalse(windows.places.isEmpty)
        XCTAssertEqual(windows.frames, arranged)
    }

    func testChangingUsableDisplayAreaInvalidatesCachedLayout() async throws {
        let windows = pairFixture()
        let worker = engine(windows)
        let first = await worker.arrangeManually().issues
        XCTAssertTrue(first.isEmpty)
        let changed = Display(id: display.id, frame: display.frame,
            visibleFrame: display.visibleFrame.insetBy(dx: 0, dy: 20), stageExtent: 160)
        windows.displays = [changed]
        clearWrites(windows)
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let targets = try Geometry.pair(in: changed.layoutArea(), gap: 9)
        XCTAssertEqual(windows.frames[a], targets[0]); XCTAssertEqual(windows.frames[b], targets[1])
        XCTAssertFalse(windows.places.isEmpty)
    }

    func testChangingReportedSizeLimitsInvalidatesCachedLayout() async {
        let windows = pairFixture()
        let worker = engine(windows)
        let first = await worker.arrangeManually().issues
        XCTAssertTrue(first.isEmpty)
        windows.minimums[b] = CGSize(width: 1000, height: 600)
        clearWrites(windows)
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty, "\(issues.map(\.message))")
        XCTAssertEqual(windows.frames[b]?.width, 1000)
        XCTAssertFalse(windows.resizes.isEmpty)
    }

    func testCorrectHiddenPairAndVisibleSingleBothRequireNoWrites() async throws {
        let area = try display.layoutArea()
        let targets = try Geometry.pair(in: area, gap: 9)
        let windows = FakeWindows(displays: [display], frames: [a: targets[0], b: targets[1], c: area], visible: [c])
        windows.hiddenGroups = [WindowGroup(members: [a, b])]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty); assertNoWrites(windows)
    }

    func testCorrectAutomaticWindowRequiresNoWrites() async throws {
        let windows = FakeWindows(displays: [display], frames: [a: try display.layoutArea()], visible: [a])
        let issues = await engine(windows).arrangeNewWindows([a]).issues
        XCTAssertTrue(issues.isEmpty); assertNoWrites(windows)
    }

    func testFailedLayoutIsNotCachedAsSuccess() async {
        let windows = pairFixture()
        windows.minimums = [a: CGSize(width: 900, height: 600), b: CGSize(width: 800, height: 500)]
        let worker = engine(windows)
        let failed = await worker.arrangeManually().issues
        XCTAssertFalse(failed.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
        windows.minimums.removeAll()
        clearWrites(windows)
        let repaired = await worker.arrangeManually().issues
        XCTAssertTrue(repaired.isEmpty)
        XCTAssertFalse(windows.places.isEmpty)
    }

    func testPositionDependentWidthClampIsNotRememberedAsApplicationMaximum() async throws {
        let screen = Display(id: 2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1320), stageExtent: 181)
        let area = try screen.layoutArea()
        let windows = FakeWindows(displays: [screen], frames: [
            a: CGRect(x: 193, y: 38, width: 740, height: 1304),
            b: CGRect(x: 1020, y: 38, width: 1532, height: 1304)
        ], visible: [a, b])
        windows.exposesConstraints = false
        windows.maximums[a] = CGSize(width: 740, height: CGFloat.infinity)
        windows.rightEdges[b] = area.maxX
        let worker = engine(windows)
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty, "\(issues.map(\.message))")
        XCTAssertEqual(windows.frames[a], CGRect(x: 199, y: 39, width: 740, height: 1302))
        XCTAssertEqual(windows.frames[b], CGRect(x: 948, y: 39, width: 1603, height: 1302))
        clearWrites(windows)
        let repeated = await worker.arrangeManually().issues
        XCTAssertTrue(repeated.isEmpty); assertNoWrites(windows)
    }

    func testResponsiveWindowCanShrinkIntoRemainingPairSpace() async {
        let screen = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2000, height: 1100),
            visibleFrame: CGRect(x: 0, y: 30, width: 2000, height: 1030), stageExtent: 160)
        let windows = FakeWindows(displays: [screen], frames: [
            a: CGRect(x: 200, y: 100, width: 1109, height: 700),
            b: CGRect(x: 300, y: 180, width: 1500, height: 700)
        ], visible: [a, b])
        windows.exposesConstraints = false
        windows.minimums = [a: CGSize(width: 1109, height: 500), b: CGSize(width: 611, height: 400)]
        windows.narrowResetThresholds[b] = (width: 650, wideMinimum: 751)
        windows.windowsNeedingNarrowReset = [b]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty, "\(issues.map(\.message))")
        XCTAssertEqual(windows.frames[b]?.width, 674)
        XCTAssertEqual(windows.frames[a]?.width, 1109)
        XCTAssertEqual(windows.frames[b]!.minX - windows.frames[a]!.maxX, 9)
    }
}
