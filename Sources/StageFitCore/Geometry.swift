import CoreGraphics
import Foundation

public struct LayoutConfiguration: Sendable {
    public var margin: CGFloat = 9
    public var fallbackSidebarWidth: CGFloat = 190
    public init() {}
}

public struct Display: Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let stageExtent: CGFloat

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, stageExtent: CGFloat = 0) {
        self.id = id
        self.frame = frame
        self.visibleFrame = frame.intersection(visibleFrame)
        self.stageExtent = stageExtent
    }

    public func layoutArea(configuration: LayoutConfiguration = .init()) throws -> CGRect {
        guard visibleFrame.isUsable else { throw LayoutError.insufficientSpace }
        let margin = configuration.margin
        let sidebar = stageExtent > 0 ? stageExtent + margin : configuration.fallbackSidebarWidth
        let area = CGRect(x: (visibleFrame.minX + sidebar).rounded(),
                          y: (visibleFrame.minY + margin).rounded(),
                          width: (visibleFrame.width - sidebar - margin).rounded(),
                          height: (visibleFrame.height - 2 * margin).rounded())
        guard area.size.width > 0, area.size.height > 0, area.isUsable else { throw LayoutError.insufficientSpace }
        return area
    }
}

public enum Geometry {
    public static func display(for window: CGRect, in displays: [Display]) -> Display? {
        displays.max { overlap(window, $0.frame) < overlap(window, $1.frame) }
            .flatMap { overlap(window, $0.frame) > 0 ? $0 : nil }
    }

    public static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    public static func near(_ actual: CGRect, _ target: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(actual.minX - target.minX) <= tolerance && abs(actual.minY - target.minY) <= tolerance &&
        abs(actual.width - target.width) <= tolerance && abs(actual.height - target.height) <= tolerance
    }

    public static func fits(_ actual: CGRect, inside target: CGRect) -> Bool {
        actual.isUsable && abs(actual.minX - target.minX) <= 1 && abs(actual.minY - target.minY) <= 1 &&
        actual.width <= target.width + 1 && actual.height <= target.height + 1
    }

    public static func pair(in area: CGRect, gap: CGFloat,
                            minimumLeft: CGFloat = 1, minimumRight: CGFloat = 1) throws -> [CGRect] {
        let available = area.width - gap
        guard available >= minimumLeft + minimumRight else { throw LayoutError.pairDoesNotFit }
        let left = max(minimumLeft, min(floor(available / 2), available - minimumRight))
        return [CGRect(x: area.minX, y: area.minY, width: left, height: area.height),
                CGRect(x: area.minX + left + gap, y: area.minY,
                       width: available - left, height: area.height)]
    }

    // NSScreen uses bottom-left coordinates; AX and Quartz use top-left coordinates.
    public static func accessibilityFrame(_ rect: CGRect, referenceTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: referenceTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

public struct RenderedWindow: Sendable {
    public let pid: Int32
    public let frame: CGRect
    public init(pid: Int32, frame: CGRect) { self.pid = pid; self.frame = frame }
}

public struct StageStrip: Sendable {
    public let screenOrigin: CGPoint
    public let frame: CGRect
    public let buttons: [CGRect]
    public init(screenOrigin: CGPoint, frame: CGRect, buttons: [CGRect]) {
        self.screenOrigin = screenOrigin; self.frame = frame; self.buttons = buttons
    }
}

public enum StageGeometry {
    public static func extent(on display: Display, strips: [StageStrip],
                              rendered: [RenderedWindow]) -> CGFloat {
        var right = display.visibleFrame.minX
        for strip in strips {
            guard abs(strip.screenOrigin.x - display.frame.minX) <= 1,
                  abs(strip.screenOrigin.y - display.frame.minY) <= 1,
                  strip.frame.minX >= display.visibleFrame.minX,
                  strip.frame.minX <= display.visibleFrame.minX + display.visibleFrame.width / 4 else { continue }
            for window in rendered where window.frame.isUsable {
                let frame = window.frame
                guard abs(frame.minX - strip.frame.minX) <= 2 else { continue }
                let isThumbnail = strip.buttons.contains { button in
                    frame.width <= button.width + 2 && frame.height <= button.height + 32 &&
                    frame.minY < button.maxY && frame.maxY > button.minY
                }
                if isThumbnail { right = max(right, min(display.visibleFrame.maxX, frame.maxX)) }
            }
        }
        return right - display.visibleFrame.minX
    }

    public static func isVisible(pid: Int32, frame: CGRect, rendered: [RenderedWindow]) -> Bool {
        rendered.contains { $0.pid == pid && Geometry.near($0.frame, frame, tolerance: 2) }
    }
}

extension CGRect {
    public var isUsable: Bool {
        !isNull && !isInfinite && minX.isFinite && minY.isFinite &&
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
