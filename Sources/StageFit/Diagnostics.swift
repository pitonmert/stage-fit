import Foundation
import StageFitCore

@MainActor enum Diagnostics {
    static func report() async throws -> String {
        let access = AccessibilityWindows()
        let capture = try await access.capture(only: nil)
        let desktop = capture.desktop
        func frame(_ rect: CGRect) -> [String: Double] {
            ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        func size(_ value: CGSize?) -> Any {
            guard let value else { return NSNull() }
            return ["width": value.width.isFinite ? value.width : -1,
                    "height": value.height.isFinite ? value.height : -1]
        }
        func identity(_ id: WindowID) -> String { "\(id.pid):\(id.serial)" }
        let displays: [[String: Any]] = desktop.displays.map { display in
            ["id": display.id, "frame": frame(display.frame), "visibleFrame": frame(display.visibleFrame),
             "layoutArea": (try? display.layoutArea()).map(frame) as Any? ?? NSNull(),
             "stageExtent": display.stageExtent,
             "stageReserveWidth": LayoutConfiguration().stageReserveWidth]
        }
        var windows: [[String: Any]] = []
        for window in desktop.windows {
            let limits = await access.sizeConstraints(of: window.id)
            windows.append(["id": identity(window.id), "application": window.bundleIdentifier ?? "unknown",
                    "frame": frame(window.frame), "visible": window.isVisible,
                    "display": Geometry.display(for: window.frame, in: desktop.displays)?.id as Any? ?? NSNull(),
                    "minimumSize": size(limits.minimum), "maximumSize": size(limits.maximum)])
        }
        let groups: [[String: Any]] = desktop.hiddenGroups.map {
            ["members": $0.members.map(identity).sorted(), "complete": $0.isComplete]
        }
        let data = try JSONSerialization.data(withJSONObject: ["displays": displays, "windows": windows,
            "hiddenGroups": groups, "retryableWindows": capture.retryableIDs.map(identity).sorted()], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
