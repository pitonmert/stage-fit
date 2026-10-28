import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class FakeWindows: WindowAccess {
    var displays: [Display]
    let originals: [WindowID: CGRect]
    var frames: [WindowID: CGRect]
    var visible: Set<WindowID>
    var minimums: [WindowID: CGSize] = [:]
    var maximums: [WindowID: CGSize] = [:]
    var places: [(WindowID, CGRect)] = []
    var resizes: [WindowID] = []
    var resizeRequests: [(WindowID, CGSize)] = []
    var failNextPlacement: WindowID?
    var rejectOrigins: Set<WindowID> = []
    var delayedReadbacks = 0
    var stale: [WindowID: (CGRect, Int)] = [:]
    var onPlace: (() -> Void)?
    var captureError: Error?
    var failRestoration: Set<WindowID> = []
    var failFrameReads: Set<WindowID> = []
    var hiddenGroups: [WindowGroup] = []
    var bundleIdentifiers: [WindowID: String] = [:]
    var exposesConstraints = true
    var captureCount = 0
    var captureScopes: [Set<WindowID>?] = []
    var capturedIDs: [Set<WindowID>] = []
    var retryableIDs: Set<WindowID> = []
    var onVisibility: (() -> Void)?
    var rightEdges: [WindowID: CGFloat] = [:]
    var narrowResetThresholds: [WindowID: (width: CGFloat, wideMinimum: CGFloat)] = [:]
    var windowsNeedingNarrowReset: Set<WindowID> = []

    init(displays: [Display], frames: [WindowID: CGRect], visible: Set<WindowID>) {
        self.displays = displays; self.frames = frames; originals = frames; self.visible = visible
    }
    func capture(only ids: Set<WindowID>?) throws -> CaptureResult {
        captureCount += 1
        captureScopes.append(ids)
        if let captureError { throw captureError }
        var related = ids ?? Set(frames.keys)
        if let ids {
            for group in hiddenGroups where !group.members.isDisjoint(with: ids) { related.formUnion(group.members) }
            if !ids.isDisjoint(with: visible) { related.formUnion(visible) }
        }
        capturedIDs.append(related)
        return CaptureResult(desktop: DesktopSnapshot(displays: displays, windows: frames.compactMap { id, frame in
            guard related.contains(id), !retryableIDs.contains(id) else { return nil }
            return WindowSnapshot(id: id, frame: frame, isVisible: visible.contains(id),
                                  bundleIdentifier: bundleIdentifiers[id])
        }, hiddenGroups: hiddenGroups), retryableIDs: retryableIDs.intersection(related))
    }
    func visibility() -> [RenderedWindow] {
        onVisibility?()
        return frames.compactMap { id, frame in
            visible.contains(id) ? RenderedWindow(pid: id.pid, frame: frame) : nil
        }
    }
    func sizeConstraints(of id: WindowID) -> WindowSizeConstraints {
        exposesConstraints ? .init(minimum: minimums[id], maximum: maximums[id]) : .init()
    }
    func frame(of id: WindowID) throws -> CGRect {
        if failFrameReads.contains(id) { throw LayoutError.unavailableWindow }
        if let (old, count) = stale[id], count > 0 { stale[id] = (old, count - 1); return old }
        guard let frame = frames[id] else { throw LayoutError.unavailableWindow }
        return frame
    }
    func resize(_ id: WindowID, to size: CGSize) throws {
        guard var frame = frames[id] else { throw LayoutError.unavailableWindow }
        resizes.append(id)
        resizeRequests.append((id, size))
        if delayedReadbacks > 0 { stale[id] = (frame, delayedReadbacks) }
        var minimum = minimums[id] ?? .zero
        if let reset = narrowResetThresholds[id] {
            if size.width <= reset.width { windowsNeedingNarrowReset.remove(id) }
            if windowsNeedingNarrowReset.contains(id) { minimum.width = max(minimum.width, reset.wideMinimum) }
        }
        let maximum = maximums[id] ?? CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        frame.size = CGSize(width: min(max(size.width, minimum.width), maximum.width),
                            height: min(max(size.height, minimum.height), maximum.height))
        if let edge = rightEdges[id] { frame.size.width = min(frame.width, max(1, edge - frame.minX)) }
        frames[id] = frame
    }
    func place(_ id: WindowID, at target: CGRect) throws {
        if failRestoration.contains(id), target == originals[id] { throw LayoutError.unavailableWindow }
        if failNextPlacement == id { failNextPlacement = nil; throw LayoutError.unavailableWindow }
        places.append((id, target))
        if rejectOrigins.contains(id), target != originals[id] {
            frames[id]?.origin = CGPoint(x: target.minX + 30, y: target.minY)
        } else { frames[id]?.origin = target.origin }
        try resize(id, to: target.size)
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
        let windows = FakeWindows(displays: extraDisplay ? [primaryDisplay, upperDisplay] : [primaryDisplay], frames: [
            left: CGRect(x: 250, y: 180, width: 1100, height: 750),
            right: CGRect(x: 500, y: 210, width: 900, height: 700),
            hidden: CGRect(x: 300, y: 150, width: 800, height: 650)
        ], visible: [left, right])
        windows.hiddenGroups = [WindowGroup(members: [hidden])]
        return windows
    }
    func engine(_ windows: FakeWindows) -> LayoutEngine { LayoutEngine(access: windows, pause: { _ in }) }

    func testEqualPairThenHiddenGroupMaximize() async throws {
        let windows = fixture()
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        let expected = try Geometry.pair(in: area, gap: 9)
        XCTAssertEqual(windows.frames[left], expected[0]); XCTAssertEqual(windows.frames[right], expected[1])
        XCTAssertEqual(windows.frames[hidden], area)
        XCTAssertEqual(windows.places.last?.0, hidden)
    }

    func testHiddenPairIsArrangedTogetherWhileVisibleSingleFills() async throws {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left, right])]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        let expected = try Geometry.pair(in: area, gap: 9)
        XCTAssertEqual(windows.frames[left], expected[0])
        XCTAssertEqual(windows.frames[right], expected[1])
        XCTAssertEqual(windows.frames[hidden], area)
    }

    func testObservedPairIsRepairedAfterHidingWithoutStripMetadata() async throws {
        let windows = fixture()
        let worker = engine(windows)
        let firstIssues = await worker.arrangeManually().issues
        XCTAssertTrue(firstIssues.isEmpty)
        let expected = windows.frames
        windows.visible = [hidden]
        windows.hiddenGroups = []
        windows.frames[left] = try primaryDisplay.layoutArea()
        windows.frames[right] = try primaryDisplay.layoutArea()
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames, expected)
    }

    func testHiddenSinglesRemainIndependentRatherThanBecomingPair() async throws {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left]), WindowGroup(members: [right])]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        XCTAssertTrue(windows.frames.values.allSatisfy { $0 == area })
    }

    func testUnknownHiddenWindowsArePreservedInsteadOfGuessedAsSingles() async throws {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = []
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[right], windows.originals[right])
        XCTAssertEqual(windows.frames[hidden], try primaryDisplay.layoutArea())
    }

    func testHiddenGroupWithUnresolvedMemberIsNotFlattened() async {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left, right], isComplete: false)]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[right], windows.originals[right])
        XCTAssertFalse(windows.resizes.contains(left))
        XCTAssertFalse(windows.resizes.contains(right))
    }

    func testHiddenPairFailureRestoresBothAndOtherHiddenSingleStillFills() async throws {
        let windows = fixture()
        windows.visible = []
        windows.hiddenGroups = [WindowGroup(members: [left, right]), WindowGroup(members: [hidden])]
        windows.minimums[left] = CGSize(width: 980, height: 600)
        windows.minimums[right] = CGSize(width: 611, height: 400)
        windows.bundleIdentifiers = [left: "com.apple.systempreferences", right: "com.apple.finder"]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].diagnosticDetails.contains("group=hidden"))
        XCTAssertTrue(issues[0].diagnosticDetails.contains("com.apple.systempreferences"))
        XCTAssertTrue(issues[0].diagnosticDetails.contains("com.apple.finder"))
        XCTAssertTrue(issues[0].message.contains("more needed"))
        XCTAssertFalse(windows.resizes.contains(left))
        XCTAssertFalse(windows.resizes.contains(right))
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[right], windows.originals[right])
        XCTAssertEqual(windows.frames[hidden], try primaryDisplay.layoutArea())
    }

    func testNativeSplitOverridesRememberedPair() async throws {
        let windows = fixture()
        let worker = engine(windows)
        let firstIssues = await worker.arrangeManually().issues
        XCTAssertTrue(firstIssues.isEmpty)
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left]), WindowGroup(members: [right])]
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        XCTAssertEqual(windows.frames[left], area)
        XCTAssertEqual(windows.frames[right], area)
    }

    func testNewVisiblePairReplacesOldPairWhenStripMetadataIsUnavailable() async throws {
        let windows = fixture()
        let worker = engine(windows)
        let firstIssues = await worker.arrangeManually().issues
        XCTAssertTrue(firstIssues.isEmpty)
        windows.visible = [left, hidden]
        windows.hiddenGroups = []
        let oldPartner = windows.frames[right]
        let issues = await worker.arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames[right], oldPartner)
        XCTAssertEqual(abs(windows.frames[left]!.minX - windows.frames[hidden]!.minX), 764)
        windows.visible = [right]
        let newPair = [left: windows.frames[left]!, hidden: windows.frames[hidden]!]
        let hiddenIssues = await worker.arrangeManually().issues
        XCTAssertTrue(hiddenIssues.isEmpty)
        XCTAssertEqual(windows.frames[left], newPair[left])
        XCTAssertEqual(windows.frames[hidden], newPair[hidden])
        XCTAssertEqual(windows.frames[right], try primaryDisplay.layoutArea())
    }

    func testHiddenGroupWithThreeMembersIsPreserved() async {
        let windows = fixture()
        windows.visible = []
        windows.hiddenGroups = [WindowGroup(members: [left, right, hidden])]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.tooManyWindows.localizedDescription)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testClosedPairMemberDoesNotKeepStaleIdentityInNewGroup() async throws {
        let windows = fixture()
        let worker = engine(windows)
        let firstIssues = await worker.arrangeManually().issues
        XCTAssertTrue(firstIssues.isEmpty)
        windows.frames.removeValue(forKey: right)
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left])]
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[left], try primaryDisplay.layoutArea())
        XCTAssertNil(windows.frames[right])
    }

    func testPartialRevealOfRememberedGroupDoesNotFlattenEitherMember() async {
        let windows = fixture()
        let worker = engine(windows)
        let firstIssues = await worker.arrangeManually().issues
        XCTAssertTrue(firstIssues.isEmpty)
        let before = windows.frames
        windows.visible = [left]
        windows.hiddenGroups = []
        windows.resizes.removeAll()
        var read = 0
        windows.onVisibility = {
            read += 1
            windows.visible = read.isMultiple(of: 2) ? [self.left, self.right] : [self.left]
        }
        let issues = await worker.arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames, before)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testAutomaticBatchArrangesHiddenPairWithoutChangingOtherWindows() async throws {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left, right])]
        let issues = await engine(windows).arrangeNewWindows([left, right]).issues
        XCTAssertTrue(issues.isEmpty)
        let expected = try Geometry.pair(in: primaryDisplay.layoutArea(), gap: 9)
        XCTAssertEqual(windows.frames[left], expected[0])
        XCTAssertEqual(windows.frames[right], expected[1])
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden])
    }

    func testAutomaticPartialHiddenGroupDoesNotResizeExistingPartnerOrOverlapIt() async {
        let windows = fixture()
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left, right])]
        let issues = await engine(windows).arrangeNewWindows([right]).issues
        XCTAssertEqual(issues.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testHiddenPairAcrossDisplaysIsNotMovedOrTreatedAsTwoSingles() async throws {
        let windows = fixture(extraDisplay: true)
        windows.frames[right] = CGRect(x: -100, y: -1200, width: 900, height: 700)
        windows.visible = [hidden]
        windows.hiddenGroups = [WindowGroup(members: [left, right])]
        let before = windows.frames
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.uncertainGroup.localizedDescription)
        XCTAssertEqual(windows.frames[left], before[left])
        XCTAssertEqual(windows.frames[right], before[right])
    }

    func testVisibleOrderIsSpatialRatherThanProcessEnumeration() async throws {
        let windows = fixture()
        windows.frames[left]?.origin.x = 900
        windows.frames[right]?.origin.x = 100
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertLessThan(windows.frames[right]!.minX, windows.frames[left]!.minX)
    }

    func testUnequalMinimumWidthsShareRemainingSpace() async throws {
        let windows = fixture()
        windows.minimums[left] = CGSize(width: 960, height: 600)
        windows.minimums[right] = CGSize(width: 550, height: 400)
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[left]?.width, 960)
        XCTAssertEqual(windows.frames[right]?.width, 551)
        XCTAssertEqual(windows.frames[left]?.minX, try primaryDisplay.layoutArea().minX)
        XCTAssertEqual(windows.frames[right]!.minX - windows.frames[left]!.maxX, 9)
    }

    func testImpossiblePairRestoresBothAndPreservesHiddenWindows() async {
        let windows = fixture()
        windows.minimums[left] = CGSize(width: 980, height: 600)
        windows.minimums[right] = CGSize(width: 611, height: 400)
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertFalse(windows.places.contains { $0.0 == hidden })
    }

    func testCappedLeftWindowGivesRemainingWidthToRightWindow() async throws {
        let windows = fixture()
        windows.maximums[left] = CGSize(width: 700, height: 800)
        windows.frames[left]?.size.width = 700
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty, "\(issues.map(\.message))")
        let area = try primaryDisplay.layoutArea()
        XCTAssertEqual(windows.frames[left], CGRect(x: area.minX, y: area.minY, width: 700, height: 800))
        XCTAssertEqual(windows.frames[right], CGRect(x: area.minX + 709, y: area.minY,
                                                     width: area.width - 709, height: area.height))
        XCTAssertEqual(windows.frames[hidden], area)
    }

    func testCappedRightWindowKeepsRightAndGivesRemainingWidthToOtherWindow() async throws {
        let windows = fixture()
        windows.maximums[right] = CGSize(width: 650, height: 750)
        windows.frames[right]?.size.width = 650
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        XCTAssertEqual(windows.frames[left]?.width, area.width - 659)
        XCTAssertEqual(windows.frames[right]?.width, 650)
        XCTAssertEqual(windows.frames[right]?.height, 750)
        XCTAssertEqual(windows.frames[left]?.minX, area.minX)
        XCTAssertEqual(windows.frames[right]!.minX - windows.frames[left]!.maxX, 9)
        XCTAssertEqual(windows.frames[right]!.maxX, area.maxX)
    }

    func testBothCappedWindowsKeepGapWithoutRequiringFullCoverage() async throws {
        let windows = fixture()
        windows.maximums[left] = CGSize(width: 650, height: 800)
        windows.maximums[right] = CGSize(width: 600, height: 700)
        windows.frames[left]?.size.width = 650
        windows.frames[right]?.size.width = 600
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        let area = try primaryDisplay.layoutArea()
        XCTAssertEqual(windows.frames[left]?.width, 650)
        XCTAssertEqual(windows.frames[right]?.width, 600)
        XCTAssertEqual(windows.frames[left]?.minX, area.minX)
        XCTAssertEqual(windows.frames[right]!.minX - windows.frames[left]!.maxX, 9)
        XCTAssertLessThan(windows.frames[right]!.maxX, area.maxX)
    }

    func testNarrowerRightWindowKeepsOrderAcrossRepeatedArrangements() async throws {
        let windows = fixture()
        windows.maximums[right] = CGSize(width: 650, height: 750)
        windows.frames[right]?.size.width = 650
        let worker = engine(windows)
        let firstIssues = await worker.arrangeManually().issues
        XCTAssertTrue(firstIssues.isEmpty)
        let arranged = windows.frames
        let secondIssues = await worker.arrangeManually().issues
        XCTAssertTrue(secondIssues.isEmpty)
        XCTAssertEqual(windows.frames, arranged)
        XCTAssertLessThan(windows.frames[left]!.minX, windows.frames[right]!.minX)
    }

    func testFailureWithUnequalWidthsRestoresOriginalIdentitiesAndFrames() async {
        let windows = fixture()
        windows.maximums[right] = CGSize(width: 650, height: 750)
        windows.frames[right]?.size.width = 650
        windows.failNextPlacement = left
        let before = windows.frames
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(windows.places.first?.0, right)
        XCTAssertEqual(windows.frames, before)
        XCTAssertFalse(windows.places.contains { $0.0 == hidden })
    }

    func testCappedHeightAloneDoesNotPreventSideBySideLayout() async throws {
        let windows = fixture()
        windows.maximums[left] = CGSize(width: CGFloat.infinity, height: 800)
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[left]?.width, 755)
        XCTAssertEqual(windows.frames[right]?.width, 756)
        XCTAssertEqual(windows.frames[left]?.height, 800)
    }

    func testCappedWindowAndLargeMinimumStillRestoreWhenPairCannotFit() async {
        let windows = fixture()
        windows.minimums[left] = CGSize(width: 700, height: 600)
        windows.maximums[left] = CGSize(width: 700, height: 800)
        windows.frames[left]?.size = CGSize(width: 700, height: 750)
        windows.minimums[right] = CGSize(width: 900, height: 400)
        let before = windows.frames
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.widthDoesNotFit(required: 1609, available: 1520).localizedDescription)
        XCTAssertEqual(windows.frames, before)
        XCTAssertFalse(windows.places.contains { $0.0 == hidden })
    }

    func testMinimumHeightFailureRestoresBoth() async {
        let windows = fixture()
        windows.minimums[right] = CGSize(width: 200, height: 1100)
        // Original is feasible for the application's own minimum.
        windows.frames[right]?.size.height = 1100
        let before = windows.frames
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(windows.frames, before)
    }

    func testPlacementFailureRestoresPartiallyChangedPair() async {
        let windows = fixture()
        windows.failNextPlacement = right
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
    }

    func testRejectedCoordinatesRestoreBothAndPreserveHidden() async {
        let windows = fixture()
        windows.rejectOrigins = [right]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
    }

    func testStaleReadbacksDoNotBecomeMinimumWidths() async {
        let windows = fixture()
        windows.delayedReadbacks = 3
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames[left]?.width, 755)
        XCTAssertEqual(windows.frames[right]?.width, 756)
    }

    func testThreeVisibleWindowsCauseNoChanges() async {
        let windows = fixture()
        windows.visible.insert(hidden)
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames, windows.originals)
        XCTAssertTrue(windows.places.isEmpty); XCTAssertTrue(windows.resizes.isEmpty)
    }

    func testNoVisibleWindowsStillResizesHiddenGroups() async throws {
        let windows = fixture()
        windows.visible.removeAll()
        windows.hiddenGroups = [left, right, hidden].map { WindowGroup(members: [$0]) }
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertTrue(windows.frames.values.allSatisfy { $0 == (try? primaryDisplay.layoutArea()) })
    }

    func testAutomaticResizesOnlyRequestedNewWindow() async throws {
        let windows = fixture()
        let issues = await engine(windows).arrangeNewWindows([right]).issues
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
        let issues = await engine(windows).arrangeNewWindows([right]).issues
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
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[right], windows.originals[right])
        XCTAssertEqual(windows.frames[upper], try upperDisplay.layoutArea())
    }

    func testCancellationAfterPlacementRollsBackBeforeReturning() async {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in throw CancellationError() })
        let issues = await worker.arrangeNewWindows([right]).issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
    }

    func testWindowClosingDuringPlacementRestoresSurvivingWindow() async {
        let windows = fixture()
        windows.onPlace = { windows.frames.removeValue(forKey: self.right) }
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden])
        windows.onPlace = nil
    }

    func testRestorationFailureIsReportedRatherThanClaimingSuccess() async {
        let windows = fixture()
        windows.rejectOrigins = [right]
        windows.failRestoration = [right]
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.restoreFailed.localizedDescription)
        XCTAssertEqual(windows.frames[left], windows.originals[left])
        XCTAssertEqual(windows.frames[hidden], windows.originals[hidden])
    }

    func testCapturePermissionFailureDoesNotModifyAnyWindow() async {
        let windows = fixture()
        windows.captureError = LayoutError.accessibilityRequired
        let issues = await engine(windows).arrangeManually().issues
        XCTAssertEqual(issues.first?.message, LayoutError.accessibilityRequired.localizedDescription)
        XCTAssertTrue(windows.resizes.isEmpty)
        XCTAssertTrue(windows.places.isEmpty)
    }

    func testCancellationDuringPairProbeRestoresBothWindows() async {
        let windows = fixture()
        let worker = LayoutEngine(access: windows, pause: { _ in if !windows.resizes.isEmpty { throw CancellationError() } })
        let issues = await worker.arrangeManually().issues
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(windows.frames, windows.originals)
    }

}
