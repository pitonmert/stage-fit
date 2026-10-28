import CoreGraphics
import XCTest
@testable import StageFitCore

@MainActor final class UnsupportedGroupTests: XCTestCase {
    let display = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1320), stageExtent: 181)
    let members = (1...3).map { WindowID(pid: Int32($0), serial: UInt64($0)) }
    let other = WindowID(pid: 4, serial: 4)
    let applicationGroups = [
        ["com.apple.Music", "com.apple.mail", "com.apple.MobileSMS"],
        ["net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.apple.MobileSMS"]
    ]

    func fixture(applications: [String], hidden: Bool = false) -> FakeWindows {
        let windows = FakeWindows(displays: [display], frames: Dictionary(uniqueKeysWithValues:
            (members + [other]).enumerated().map { index, id in
                (id, CGRect(x: 200 + index * 300, y: 80, width: 700, height: 800))
            }), visible: hidden ? [other] : Set(members))
        // These applications have the same rules as every other group.
        windows.bundleIdentifiers = Dictionary(uniqueKeysWithValues:
            zip(members, applications))
        windows.hiddenGroups = [WindowGroup(members: hidden ? Set(members) : [other])]
        return windows
    }

    func assertPreserved(_ windows: FakeWindows, _ report: LayoutReport,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(report.skipped.first?.message, LayoutError.tooManyWindows.localizedDescription, file: file, line: line)
        XCTAssertTrue(report.errors.isEmpty, file: file, line: line)
        XCTAssertTrue(report.retryableIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(windows.frames, windows.originals, file: file, line: line)
        XCTAssertTrue(windows.resizes.isEmpty, file: file, line: line)
        XCTAssertTrue(windows.places.isEmpty, file: file, line: line)
    }

    func testFormerSpecialVisibleGroupIsPreservedManually() async {
        for applications in applicationGroups {
            let windows = fixture(applications: applications)
            let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
            assertPreserved(windows, report)
        }
    }

    func testFormerSpecialHiddenGroupIsPreservedWhileVisibleSingleFills() async throws {
        for applications in applicationGroups {
            let windows = fixture(applications: applications, hidden: true)
            let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeManually()
            XCTAssertEqual(report.skipped.first?.message, LayoutError.tooManyWindows.localizedDescription)
            for id in members {
                XCTAssertEqual(windows.frames[id], windows.originals[id])
                XCTAssertFalse(windows.resizes.contains(id))
            }
            XCTAssertEqual(windows.frames[other], try display.layoutArea())
        }
    }

    func testAutomaticWholeOrPartialVisibleGroupIsPreserved() async {
        for applications in applicationGroups {
            for ids in [Set(members), Set(members.prefix(2)), [members[2]]] {
                let windows = fixture(applications: applications)
                let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeNewWindows(ids)
                assertPreserved(windows, report)
            }
        }
    }

    func testAutomaticHiddenGroupIsPreserved() async {
        for applications in applicationGroups {
            for ids in [Set(members), Set(members.prefix(2)), [members[2]]] {
                let windows = fixture(applications: applications, hidden: true)
                let report = await LayoutEngine(access: windows, pause: { _ in }).arrangeNewWindows(ids)
                assertPreserved(windows, report)
            }
        }
    }
}
