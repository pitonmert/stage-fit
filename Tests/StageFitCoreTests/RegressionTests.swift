import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class RegressionTests: XCTestCase {
    let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 33, width: 1728, height: 994), stageExtent: 161)
    let a = WindowID(pid: 10, serial: 1)
    let b = WindowID(pid: 20, serial: 2)

    func fixture() -> FakeWindows {
        FakeWindows(displays: [display], frames: [
            a: CGRect(x: 250, y: 100, width: 1100, height: 700),
            b: CGRect(x: 500, y: 100, width: 900, height: 700)], visible: [a, b])
    }

    func testUnreportedLimitsExpireWithoutSlidingOnRepeatedManualRequests() async throws {
        let windows = fixture()
        windows.frames.removeValue(forKey: b); windows.visible = [a]
        windows.exposesConstraints = false
        windows.maximums[a] = CGSize(width: 700, height: 800)
        var time: TimeInterval = 0
        let worker = LayoutEngine(access: windows, now: { time }, pause: { _ in })
        let first = await worker.arrangeManually()
        XCTAssertTrue(first.issues.isEmpty)
        windows.maximums.removeValue(forKey: a)
        windows.resizes.removeAll(); windows.places.removeAll()
        for instant: TimeInterval in [1, 2, 4.9] {
            time = instant
            let report = await worker.arrangeManually()
            XCTAssertTrue(report.issues.isEmpty)
            XCTAssertTrue(windows.resizes.isEmpty); XCTAssertTrue(windows.places.isEmpty)
        }
        time = 5
        let refreshed = await worker.arrangeManually()
        XCTAssertTrue(refreshed.issues.isEmpty)
        XCTAssertEqual(windows.frames[a], try display.layoutArea())
    }

    func testMeasuredFailureIsCachedAndRetriedAfterExpiry() async {
        let windows = fixture()
        windows.exposesConstraints = false
        windows.minimums = [a: CGSize(width: 900, height: 400), b: CGSize(width: 800, height: 400)]
        var time: TimeInterval = 0
        let worker = LayoutEngine(access: windows, now: { time }, pause: { _ in })
        let first = await worker.arrangeManually()
        XCTAssertEqual(first.skipped.count, 1); XCTAssertTrue(first.errors.isEmpty)
        XCTAssertFalse(windows.resizes.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
        windows.resizes.removeAll(); windows.places.removeAll()
        windows.minimums.removeAll()
        time = 4.9
        let cached = await worker.arrangeManually()
        XCTAssertEqual(cached.skipped.first?.message, first.skipped.first?.message)
        XCTAssertTrue(windows.resizes.isEmpty); XCTAssertTrue(windows.places.isEmpty)
        time = 5
        let retried = await worker.arrangeManually()
        XCTAssertTrue(retried.issues.isEmpty)
        XCTAssertFalse(windows.resizes.isEmpty)
    }

    func testStableSingletonReplacesRememberedPairWithoutNativeMetadata() async throws {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in })
        let first = await worker.arrangeManually()
        XCTAssertTrue(first.issues.isEmpty)
        let partner = windows.frames[b]
        windows.visible = [a]
        let report = await worker.arrangeManually()
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(windows.frames[a], try display.layoutArea())
        XCTAssertEqual(windows.frames[b], partner)
        XCTAssertFalse(report.skipped.isEmpty) // The hidden partner has unknown membership.
    }

    func testIncompleteNativeMembershipCannotBeOverriddenByStableVisibility() async {
        let windows = fixture()
        windows.visible = [a]
        windows.hiddenGroups = [WindowGroup(members: [a, b], isComplete: false)]
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertEqual(report.skipped.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testUnreadableRememberedPartnerDoesNotConfirmAGroupSplit() async {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in })
        _ = await worker.arrangeManually()
        let arranged = windows.frames
        windows.visible = [a]
        windows.retryableIDs = [b]
        windows.resizes.removeAll()
        let report = await worker.arrangeManually()
        XCTAssertEqual(report.skipped.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames, arranged)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testIncompleteVisibleNativeGroupWaitsBeforeAutomaticSizing() async {
        let windows = fixture()
        windows.hiddenGroups = [WindowGroup(members: [a], isComplete: false)]
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeNewWindows([a])
        XCTAssertEqual(report.retryableIDs, [a])
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testLateWindowReadinessSurvivesDiscoveryUntilSuccessfulCompletion() async throws {
        var tracker = NewWindowTracker()
        tracker.start(existing: [b])
        let discovered = tracker.discover([a], pid: a.pid)
        let windows = fixture()
        windows.retryableIDs = [a]
        let worker = LayoutEngine(access: windows, pause: { _ in })
        let pending = await worker.arrangeNewWindows(discovered)
        XCTAssertEqual(pending.retryableIDs, [a])
        let retry = tracker.complete(discovered, retryable: pending.retryableIDs, now: 0)
        XCTAssertEqual(retry.scheduled.first?.delay, 0.25)
        XCTAssertTrue(tracker.claimRetry(a, now: 0.25))
        windows.retryableIDs.removeAll()
        let completed = await worker.arrangeNewWindows([a])
        XCTAssertTrue(completed.issues.isEmpty)
        XCTAssertEqual(windows.frames[a], try display.layoutArea())
        XCTAssertEqual(windows.frames[b], windows.originals[b])
        _ = tracker.complete([a], retryable: completed.retryableIDs, now: 0.25)
        XCTAssertTrue(tracker.pending.isEmpty)
        XCTAssertTrue(tracker.discover([a], pid: a.pid).isEmpty)
        XCTAssertTrue(windows.captureScopes.allSatisfy { $0 == [a] })
    }

    func testUnreadableMemberKeepsTheWholeNewBatchPending() async throws {
        let windows = fixture()
        windows.retryableIDs = [b]
        let ids: Set<WindowID> = [a, b]
        let worker = LayoutEngine(access: windows, pause: { _ in })
        let pending = await worker.arrangeNewWindows(ids)
        XCTAssertEqual(pending.retryableIDs, ids)
        XCTAssertTrue(windows.resizes.isEmpty)
        windows.retryableIDs.removeAll()
        let completed = await worker.arrangeNewWindows(ids)
        XCTAssertTrue(completed.issues.isEmpty)
        XCTAssertTrue(completed.retryableIDs.isEmpty)
        let area = try display.layoutArea()
        XCTAssertEqual(windows.frames[a], area)
        XCTAssertEqual(windows.frames[b], area)
    }

    func testRetryDelaysExhaustAfterFourAttempts() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [])
        _ = tracker.discover([a], pid: a.pid)
        var time: TimeInterval = 0
        for expected: TimeInterval in [0.25, 0.5, 1, 2] {
            let result = tracker.complete([a], retryable: [a], now: time)
            XCTAssertEqual(result.scheduled.first?.delay, expected)
            time += expected
            XCTAssertTrue(tracker.claimRetry(a, now: time))
        }
        let exhausted = tracker.complete([a], retryable: [a], now: time)
        XCTAssertEqual(exhausted.expired, [a]); XCTAssertTrue(exhausted.scheduled.isEmpty)
        XCTAssertFalse(tracker.claimRetry(a, now: time))
    }

    func testRetryDeadlineAndStopDiscardPendingWindows() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [])
        _ = tracker.discover([a], pid: a.pid)
        _ = tracker.complete([a], retryable: [a], now: 0)
        XCTAssertFalse(tracker.claimRetry(a, now: 5.01))
        XCTAssertTrue(tracker.pending.isEmpty)
        _ = tracker.discover([b], pid: b.pid)
        _ = tracker.complete([b], retryable: [b], now: 10)
        tracker.stop()
        XCTAssertFalse(tracker.claimRetry(b, now: 10.25))
        XCTAssertTrue(tracker.pending.isEmpty)
    }

    func testBaselineDoesNotEraseNewWindowsDiscoveredDuringStartup() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [])
        _ = tracker.discover([a], pid: a.pid)
        tracker.baseline([b])
        XCTAssertEqual(tracker.pending, [a])
        XCTAssertTrue(tracker.discover([b], pid: b.pid).isEmpty)
    }

    func testScopedSelectionReadsOnlyTheRequestedNativeGroup() {
        let frame = CGRect(x: 250, y: 100, width: 700, height: 700)
        let selection = WindowCaptureSelection(requested: [a], frames: [a: frame],
            numbers: [a: 101], groups: [[101, 102], [103]], server: [
                ServerWindow(number: 101, pid: a.pid, frame: frame),
                ServerWindow(number: 102, pid: b.pid, frame: frame),
                ServerWindow(number: 103, pid: 30, frame: frame)],
            rendered: [RenderedWindow(pid: 30, frame: frame)], displays: [display])
        XCTAssertEqual(selection.pids, [a.pid, b.pid])
        XCTAssertEqual(selection.numbers, [101, 102])
    }

    func testScopedFallbackExcludesOtherDisplays() {
        let other = Display(id: 2, frame: CGRect(x: 2000, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 2000, y: 33, width: 1728, height: 994))
        let frame = CGRect(x: 250, y: 100, width: 700, height: 700)
        let selection = WindowCaptureSelection(requested: [a], frames: [a: frame], numbers: [:], groups: [],
            server: [], rendered: [RenderedWindow(pid: b.pid, frame: frame),
                RenderedWindow(pid: 30, frame: CGRect(x: 2200, y: 100, width: 700, height: 700))],
            displays: [display, other])
        XCTAssertEqual(selection.pids, [a.pid, b.pid])
    }

    func testNoEligibleWindowsIsReportedWithoutAnAlert() async {
        let windows = FakeWindows(displays: [display], frames: [:], visible: [])
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.skipped.first?.message, LayoutError.noEligibleWindows.localizedDescription)
    }

    func testDelayedPlacementReadbacksSettleBeforeAnotherWrite() async throws {
        let windows = fixture()
        windows.delayedReadbacks = 5
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertTrue(report.issues.isEmpty)
        let targets = try Geometry.pair(in: display.layoutArea(), gap: 9)
        XCTAssertEqual(windows.frames[a], targets[0]); XCTAssertEqual(windows.frames[b], targets[1])
        XCTAssertEqual(windows.places.count, 2)
    }

    func testUnavailableHiddenGroupDoesNotPreventOtherGroupsFromArranging() async throws {
        let windows = fixture()
        let visible = WindowID(pid: 30, serial: 3)
        windows.frames[visible] = CGRect(x: 300, y: 100, width: 700, height: 600)
        windows.visible = [visible]
        windows.hiddenGroups = [WindowGroup(members: [a]), WindowGroup(members: [b])]
        windows.failFrameReads = [a]
        let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(windows.frames[a], windows.originals[a])
        XCTAssertEqual(windows.frames[b], try display.layoutArea())
        XCTAssertEqual(windows.frames[visible], try display.layoutArea())
    }

    func testBlockingWorkerAllowsMainActorToRespond() async {
        let access = BlockingAccess()
        _ = await LayoutEngine(access: access).arrangeNewWindows([a])
        let responded = await access.responded
        XCTAssertTrue(responded)
    }
}

private actor BlockingAccess: WindowAccess {
    private(set) var responded = false
    func capture(only ids: Set<WindowID>?) -> CaptureResult {
        let signal = DispatchSemaphore(value: 0)
        Task { @MainActor in signal.signal() }
        responded = signal.wait(timeout: .now() + 2) == .success
        return CaptureResult(desktop: DesktopSnapshot(displays: [], windows: []))
    }
    func frame(of window: WindowID) throws -> CGRect { throw LayoutError.unavailableWindow }
    func resize(_ window: WindowID, to size: CGSize) {}
    func place(_ window: WindowID, at frame: CGRect) {}
}
