import CoreGraphics
import XCTest
@testable import StageFitCore

final class GeometryTests: XCTestCase {
    let primaryDisplay = Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                          visibleFrame: CGRect(x: 0, y: 33, width: 1728, height: 994), stageExtent: 161)
    let upperDisplay = Display(id: 2, frame: CGRect(x: -422, y: -1440, width: 2560, height: 1440),
                      visibleFrame: CGRect(x: -422, y: -1410, width: 2560, height: 1410), stageExtent: 181)

    func testPerDisplayAreaPreservesMeasuredStageSpace() throws {
        XCTAssertEqual(try primaryDisplay.layoutArea(), CGRect(x: 170, y: 42, width: 1549, height: 976))
        XCTAssertEqual(try upperDisplay.layoutArea(), CGRect(x: -232, y: -1401, width: 2361, height: 1392))
    }

    func testVisibleFrameIsClampedToPhysicalDisplay() throws {
        let screen = Display(id: 1, frame: CGRect(x: -422, y: -1440, width: 2560, height: 1440),
                             visibleFrame: CGRect(x: -500, y: -1410, width: 2800, height: 2000), stageExtent: 181)
        XCTAssertEqual(try screen.layoutArea(), CGRect(x: -232, y: -1401, width: 2361, height: 1392))
    }

    func testCoordinatesUseFirstDisplayTopRatherThanFocusedScreen() {
        XCTAssertEqual(Geometry.accessibilityFrame(CGRect(x: -422, y: 1117, width: 2560, height: 1440), referenceTop: 1117), upperDisplay.frame)
    }

    func testDisplaySelectionUsesLargestOverlapWithNegativeCoordinates() {
        let straddling = CGRect(x: 100, y: -600, width: 900, height: 800)
        XCTAssertEqual(Geometry.display(for: straddling, in: [primaryDisplay, upperDisplay])?.id, 2)
        XCTAssertNil(Geometry.display(for: CGRect(x: 9000, y: 9000, width: 100, height: 100), in: [primaryDisplay, upperDisplay]))
    }

    func testAllEdgesAndPairGapAreNinePoints() throws {
        let area = try upperDisplay.layoutArea()
        let pair = try Geometry.pair(in: area, gap: 9)
        XCTAssertEqual(pair[0], CGRect(x: -232, y: -1401, width: 1176, height: 1392))
        XCTAssertEqual(pair[1], CGRect(x: 953, y: -1401, width: 1176, height: 1392))
        XCTAssertEqual(pair[1].minX - pair[0].maxX, 9)
        XCTAssertEqual(upperDisplay.visibleFrame.maxX - pair[1].maxX, 9)
        XCTAssertEqual(upperDisplay.visibleFrame.maxY - pair[1].maxY, 9)
        XCTAssertEqual(pair[0].minY - upperDisplay.visibleFrame.minY, 9)
        XCTAssertEqual(pair[0].minX - (upperDisplay.visibleFrame.minX + upperDisplay.stageExtent), 9)
    }

    func testLargeMinimumReceivesSpaceFromOtherWindow() throws {
        let area = try primaryDisplay.layoutArea()
        let pair = try Geometry.pair(in: area, gap: 9, minimumLeft: 980, minimumRight: 560)
        XCTAssertEqual(pair.map(\.width), [980, 560])
        XCTAssertEqual(pair[1].maxX, area.maxX)
    }

    func testMinimumOnRightAndOddWidthKeepExactGapAndEdges() throws {
        let area = CGRect(x: 12, y: 30, width: 1600, height: 900)
        let pair = try Geometry.pair(in: area, gap: 9, minimumLeft: 500, minimumRight: 980)
        XCTAssertEqual(pair.map(\.width), [611, 980])
        XCTAssertEqual(pair[1].minX - pair[0].maxX, 9)
        XCTAssertEqual(pair[1].maxX, area.maxX)
    }

    func testCombinedMinimumWidthsExceedAvailableSpace() throws {
        XCTAssertThrowsError(try Geometry.pair(in: primaryDisplay.layoutArea(), gap: 9, minimumLeft: 980, minimumRight: 611)) {
            XCTAssertEqual($0 as? LayoutError, .pairDoesNotFit)
        }
    }

    func testUnmeasuredStageAreaUsesFallbackReserve() throws {
        let screen = Display(id: 1, frame: primaryDisplay.frame, visibleFrame: primaryDisplay.visibleFrame)
        XCTAssertEqual(try screen.layoutArea().minX, 190)
    }

    func testTooSmallOrMissingUsableAreaIsRejected() {
        for visible in [CGRect(x: 0, y: 0, width: 120, height: 90), CGRect(x: 2000, y: 0, width: 20, height: 20)] {
            let screen = Display(id: 1, frame: primaryDisplay.frame, visibleFrame: visible)
            XCTAssertThrowsError(try screen.layoutArea())
        }
    }

    func testRenderedThumbnailMeasurementAllowsAppOwnedWindows() {
        let strip = StageStrip(screenOrigin: upperDisplay.frame.origin,
                               frame: CGRect(x: -410, y: -1300, width: 210, height: 900),
                               buttons: [CGRect(x: -410, y: -1200, width: 180, height: 110)])
        let thumbnail = RenderedWindow(pid: 123, frame: CGRect(x: -410, y: -1200, width: 169, height: 100))
        let largeWindow = RenderedWindow(pid: 999, frame: CGRect(x: -410, y: -1200, width: 1800, height: 1000))
        XCTAssertEqual(StageGeometry.extent(on: upperDisplay, strips: [strip], rendered: [thumbnail, largeWindow]), 181)
        XCTAssertEqual(StageGeometry.extent(on: primaryDisplay, strips: [strip], rendered: [thumbnail]), 0)
    }

    func testVisibilityNeedsPIDAndFullFrameNotThumbnailOrTitle() {
        let frame = CGRect(x: 190, y: 39, width: 1000, height: 900)
        XCTAssertTrue(StageGeometry.isVisible(pid: 1, frame: frame, rendered: [.init(pid: 1, frame: frame)]))
        XCTAssertFalse(StageGeometry.isVisible(pid: 2, frame: frame, rendered: [.init(pid: 1, frame: frame)]))
        XCTAssertFalse(StageGeometry.isVisible(pid: 1, frame: frame, rendered: [.init(pid: 1, frame: CGRect(x: 12, y: 300, width: 169, height: 100))]))
    }
}
