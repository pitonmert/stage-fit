import CoreGraphics
import XCTest
@testable import StageFitCore

final class TrackerTests: XCTestCase {
    let first = WindowID(pid: 10, serial: 1)
    let second = WindowID(pid: 10, serial: 2)
    let other = WindowID(pid: 20, serial: 3)

    func testStartupLeavesExistingWindowsAloneAndDetectsOnlyNewWindows() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [first, other])
        XCTAssertTrue(tracker.discover([first], pid: 10).isEmpty)
        XCTAssertTrue(tracker.discover([other], pid: 20).isEmpty)
        XCTAssertEqual(tracker.discover([first, second], pid: 10), [second])
    }

    func testStartingTwiceDoesNotAbsorbAnUnprocessedNewWindow() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [first])
        tracker.start(existing: [first, second])
        XCTAssertEqual(tracker.discover([first, second], pid: 10), [second])
    }

    func testStopIgnoresEventsAndRestartResetsIdentityTracking() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [first])
        tracker.stop()
        XCTAssertFalse(tracker.isRunning)
        XCTAssertTrue(tracker.discover([second], pid: 10).isEmpty)
        tracker.start(existing: [first, second])
        XCTAssertTrue(tracker.discover([first, second], pid: 10).isEmpty)
        XCTAssertEqual(tracker.discover([other], pid: 20), [other])
    }

    func testClosedWindowsAndTerminatedAppsArePrunedIndependently() {
        var tracker = NewWindowTracker()
        tracker.start(existing: [first, other])
        XCTAssertEqual(tracker.discover([second], pid: 10), [second])
        XCTAssertTrue(tracker.discover([other], pid: 20).isEmpty)
        tracker.remove(pid: 20)
        XCTAssertEqual(tracker.discover([other], pid: 20), [other])
    }
}

@MainActor final class QueueTests: XCTestCase {
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Queue did not reach the expected state", file: file, line: line)
    }

    func testManualAndAutomaticJobsNeverOverlap() async {
        var active = 0
        var maximumActive = 0
        var completed: [LayoutQueue.Job] = []
        let queue = LayoutQueue { job in
            active += 1; maximumActive = max(maximumActive, active)
            await Task.yield()
            completed.append(job); active -= 1
        }
        let id = WindowID(pid: 1, serial: 1)
        queue.submit(.automatic([id])); queue.submit(.manual)
        await eventually { completed.count == 2 && !queue.isBusy }
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(completed, [.automatic([id]), .manual])
    }

    func testAutomaticBatchesMergeAndManualRequestsCoalesce() async {
        var release: CheckedContinuation<Void, Never>?
        var completed: [LayoutQueue.Job] = []
        var started = false
        let queue = LayoutQueue { job in
            if !started {
                started = true
                await withCheckedContinuation { release = $0 }
            }
            completed.append(job)
        }
        let first = WindowID(pid: 1, serial: 1), second = WindowID(pid: 1, serial: 2)
        queue.submit(.manual)
        await eventually { release != nil }
        queue.submit(.automatic([first])); queue.submit(.automatic([second]))
        queue.submit(.manual); queue.submit(.manual)
        release?.resume()
        await eventually { completed.count == 3 && !queue.isBusy }
        XCTAssertEqual(completed, [.manual, .automatic([first, second]), .manual])
    }

    func testSwapClicksStaySeparateAndRunAfterCurrentLayout() async {
        var release: CheckedContinuation<Void, Never>?
        var completed: [LayoutQueue.Job] = []
        let queue = LayoutQueue { job in
            if completed.isEmpty { await withCheckedContinuation { release = $0 } }
            completed.append(job)
        }
        queue.submit(.manual)
        await eventually { release != nil }
        queue.submit(.swapVisible); queue.submit(.swapVisible)
        queue.submit(.manual); queue.submit(.manual)
        release?.resume()
        await eventually { completed.count == 4 && !queue.isBusy }
        XCTAssertEqual(completed, [.manual, .swapVisible, .swapVisible, .manual])
    }

    func testDisablingAutomaticWorkPreservesQueuedSwap() async {
        var release: CheckedContinuation<Void, Never>?
        var completed: [LayoutQueue.Job] = []
        let queue = LayoutQueue { job in
            if case .automatic = job { await withCheckedContinuation { release = $0 } }
            completed.append(job)
        }
        let id = WindowID(pid: 1, serial: 1)
        queue.submit(.automatic([id]))
        await eventually { release != nil }
        queue.submit(.automatic([id])); queue.submit(.swapVisible)
        queue.cancelAutomatic(); release?.resume()
        await eventually { completed.count == 2 && !queue.isBusy }
        XCTAssertEqual(completed, [.automatic([id]), .swapVisible])
    }

    func testDisableCancelsActiveAutomaticDropsPendingAutomaticAndKeepsManual() async {
        var release: CheckedContinuation<Void, Never>?
        var completed: [LayoutQueue.Job] = []
        var automaticCancelled = false
        let queue = LayoutQueue { job in
            if case .automatic = job {
                await withCheckedContinuation { release = $0 }
                automaticCancelled = Task.isCancelled
            }
            completed.append(job)
        }
        let id = WindowID(pid: 1, serial: 1)
        queue.submit(.automatic([id]))
        await eventually { release != nil }
        queue.submit(.automatic([WindowID(pid: 1, serial: 2)])); queue.submit(.manual)
        queue.cancelAutomatic(); release?.resume()
        await eventually { completed.count == 2 && !queue.isBusy }
        XCTAssertTrue(automaticCancelled)
        XCTAssertEqual(completed, [.automatic([id]), .manual])
    }

    func testStopCancelsRunningJobAndRejectsFurtherSubmissions() async {
        var release: CheckedContinuation<Void, Never>?
        var jobs = 0
        var cancelled = false
        let queue = LayoutQueue { _ in
            jobs += 1
            await withCheckedContinuation { release = $0 }
            cancelled = Task.isCancelled
        }
        queue.submit(.manual)
        await eventually { release != nil }
        queue.submit(.manual); queue.stop(); queue.submit(.manual)
        release?.resume()
        await eventually { !queue.isBusy }
        XCTAssertEqual(jobs, 1); XCTAssertTrue(cancelled)
    }

    func testRapidManualBurstProducesOnlyOneFreshFollowUp() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var completed = 0
        let queue = LayoutQueue { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            completed += 1
        }
        queue.submit(.manual)
        await eventually { release != nil }
        for _ in 0..<200 { queue.submit(.manual) }
        release?.resume()
        await eventually { !queue.isBusy }
        XCTAssertEqual(calls, 2); XCTAssertEqual(completed, 2)
    }

    func testBurstDuringRealLayoutDoesNotRepeatWindowWrites() async throws {
        let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1100),
            visibleFrame: CGRect(x: 0, y: 30, width: 1800, height: 1030), stageExtent: 160)
        let a = WindowID(pid: 10, serial: 1), b = WindowID(pid: 20, serial: 2)
        let windows = FakeWindows(displays: [display], frames: [
            a: CGRect(x: 250, y: 100, width: 650, height: 700),
            b: CGRect(x: 500, y: 150, width: 900, height: 700)
        ], visible: [a, b])
        windows.exposesConstraints = false
        windows.maximums[a] = CGSize(width: 700, height: 800)
        var release: CheckedContinuation<Void, Never>?
        var paused = false
        let worker = LayoutEngine(access: windows, pause: { _ in
            if !paused { paused = true; await withCheckedContinuation { release = $0 } }
        })
        var completed = 0
        var firstWriteCount = 0
        let queue = LayoutQueue { _ in
            let issues = await worker.arrangeManually().issues
            XCTAssertTrue(issues.isEmpty)
            completed += 1
            if completed == 1 { firstWriteCount = windows.resizes.count + windows.places.count }
        }
        queue.submit(.manual)
        await eventually { release != nil }
        for _ in 0..<200 { queue.submit(.manual) }
        release?.resume()
        await eventually { !queue.isBusy }
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(windows.captureCount, 4)
        XCTAssertGreaterThan(firstWriteCount, 0)
        XCTAssertEqual(windows.resizes.count + windows.places.count, firstWriteCount)
    }

    func testQueuedRefreshUsesNewlyVisibleGroupAndPreservesCorrectHiddenPair() async throws {
        let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1100),
            visibleFrame: CGRect(x: 0, y: 30, width: 1800, height: 1030), stageExtent: 160)
        let a = WindowID(pid: 10, serial: 1), b = WindowID(pid: 20, serial: 2), c = WindowID(pid: 30, serial: 3)
        let windows = FakeWindows(displays: [display], frames: [
            a: CGRect(x: 250, y: 100, width: 900, height: 700),
            b: CGRect(x: 500, y: 150, width: 800, height: 700),
            c: CGRect(x: 350, y: 200, width: 1000, height: 750)
        ], visible: [a, b])
        windows.hiddenGroups = [WindowGroup(members: [c])]
        var release: CheckedContinuation<Void, Never>?
        var paused = false
        let worker = LayoutEngine(access: windows, pause: { _ in
            if !paused { paused = true; await withCheckedContinuation { release = $0 } }
        })
        var completed = 0
        var pairWritesAfterFirst = 0
        let queue = LayoutQueue { _ in
            let issues = await worker.arrangeManually().issues
            XCTAssertTrue(issues.isEmpty)
            completed += 1
            if completed == 1 {
                pairWritesAfterFirst = windows.resizes.filter { $0 == a || $0 == b }.count
                windows.visible = [c]
                windows.hiddenGroups = [WindowGroup(members: [a, b])]
                windows.frames[c] = windows.originals[c]
            }
        }
        queue.submit(.manual)
        await eventually { release != nil }
        for _ in 0..<100 { queue.submit(.manual) }
        release?.resume()
        await eventually { !queue.isBusy }
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(windows.frames[c], try display.layoutArea())
        XCTAssertEqual(windows.resizes.filter { $0 == a || $0 == b }.count, pairWritesAfterFirst)
    }
}

final class PreferencesTests: XCTestCase {
    func testDefaultsAndPersistence() throws {
        let name = "StageFitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.automaticSizing); XCTAssertNil(preferences.shortcut)
        let shortcut = Shortcut(keyCode: 49, modifiers: 0x0800, label: "Space")
        preferences.automaticSizing = false; preferences.shortcut = shortcut
        let reloaded = Preferences(defaults: defaults)
        XCTAssertFalse(reloaded.automaticSizing); XCTAssertEqual(reloaded.shortcut, shortcut)
    }

    func testInvalidAndCorruptShortcutsAreIgnored() throws {
        let name = "StageFitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        defaults.set(Data("invalid JSON".utf8), forKey: "shortcut")
        XCTAssertNil(preferences.shortcut)
        preferences.shortcut = Shortcut(keyCode: 999, modifiers: 0, label: "bad")
        XCTAssertNil(preferences.shortcut)
        XCTAssertFalse(Shortcut(keyCode: 49, modifiers: 0xFFFF, label: "Space").isValid)
    }
}
