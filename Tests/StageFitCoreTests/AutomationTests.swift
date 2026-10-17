import CoreGraphics
import XCTest
@testable import StageFitCore

final class TrackerTests: XCTestCase {
    let first = WindowID(pid: 10, serial: 1)
    let second = WindowID(pid: 10, serial: 2)
    let other = WindowID(pid: 20, serial: 3)

    func testStartupSweepReturnsExistingWindowsOnlyOnce() {
        var tracker = NewWindowTracker()
        XCTAssertEqual(tracker.start(existing: [first], includeExisting: true), [first])
        XCTAssertTrue(tracker.start(existing: [first], includeExisting: true).isEmpty)
        XCTAssertTrue(tracker.discover([first], pid: 10).isEmpty)
        XCTAssertEqual(tracker.discover([first, second], pid: 10), [second])
    }

    func testEnablingLaterBaselinesExistingWindows() {
        var tracker = NewWindowTracker()
        XCTAssertTrue(tracker.start(existing: [first], includeExisting: false).isEmpty)
        XCTAssertTrue(tracker.discover([first], pid: 10).isEmpty)
        XCTAssertEqual(tracker.discover([first, second], pid: 10), [second])
    }

    func testStopIgnoresEventsAndRestartResetsIdentityTracking() {
        var tracker = NewWindowTracker()
        _ = tracker.start(existing: [first], includeExisting: true)
        tracker.stop()
        XCTAssertFalse(tracker.isRunning)
        XCTAssertTrue(tracker.discover([second], pid: 10).isEmpty)
        XCTAssertEqual(tracker.start(existing: [first], includeExisting: true), [first])
    }

    func testClosedWindowsAndTerminatedAppsArePrunedIndependently() {
        var tracker = NewWindowTracker()
        _ = tracker.start(existing: [first, other], includeExisting: false)
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
