import AppKit
import ApplicationServices
import StageFitCore

struct AccessibilityFailure: LocalizedError {
    let operation: String
    let code: AXError
    var errorDescription: String? { "\(operation) failed (Accessibility \(code.rawValue))." }
}

enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func elements(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        let rect = CGRect(origin: point, size: dimensions)
        return rect.isUsable ? rect : nil
    }
    static func setSize(_ element: AXUIElement, _ size: CGSize) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { throw LayoutError.rejectedFrame }
        let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard result == .success else { throw AccessibilityFailure(operation: "Resize", code: result) }
    }
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { throw LayoutError.rejectedFrame }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else { throw AccessibilityFailure(operation: "Move", code: result) }
    }
    static func canSet(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
    static func isEligible(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
        attribute(element, kAXMinimizedAttribute) as? Bool != true &&
        attribute(element, "AXFullScreen") as? Bool != true &&
        canSet(element, kAXSizeAttribute) && canSet(element, kAXPositionAttribute)
    }
}

@MainActor final class AccessibilityWindows: WindowAccess {
    private var elements: [WindowID: AXUIElement] = [:]
    private var serial: UInt64 = 0
    static let excluded = Set(["com.raycast.macos", "com.apple.dock", "com.apple.WindowManager",
                               "com.apple.controlcenter", "com.apple.notificationcenterui",
                               "com.pitonmert.StageFit"])

    func isEligible(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && app.activationPolicy == .regular &&
        !Self.excluded.contains(app.bundleIdentifier ?? "") && app.processIdentifier != getpid()
    }

    func id(for element: AXUIElement) -> WindowID {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let existing = elements.first(where: { $0.key.pid == pid && CFEqual($0.value, element) }) { return existing.key }
        serial += 1
        let id = WindowID(pid: pid, serial: serial)
        AXUIElementSetMessagingTimeout(element, 0.5)
        elements[id] = element
        return id
    }

    func windows(of app: NSRunningApplication) -> Set<WindowID> {
        guard isEligible(app) else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Do not interpret a transient AX failure as all of an app's windows closing.
        guard let list = AX.attribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
            return Set(elements.keys.filter { $0.pid == app.processIdentifier })
        }
        let ids = Set(list.map { id(for: $0) })
        elements = elements.filter { $0.key.pid != app.processIdentifier || ids.contains($0.key) }
        return ids
    }

    func remove(pid: pid_t) { elements = elements.filter { $0.key.pid != pid } }

    func capture(only ids: Set<WindowID>?) throws -> DesktopSnapshot {
        guard AXIsProcessTrusted() else { throw LayoutError.accessibilityRequired }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != "com.apple.loginwindow" else { return DesktopSnapshot(displays: [], windows: []) }
        let candidates: Set<WindowID>
        if let ids { candidates = ids }
        else {
            let running = NSWorkspace.shared.runningApplications.filter { isEligible($0) }
            let pids = Set(running.map(\.processIdentifier))
            elements = elements.filter { pids.contains($0.key.pid) }
            candidates = running.reduce(into: []) { $0.formUnion(windows(of: $1)) }
        }
        let frames: [(WindowID, CGRect)] = candidates.compactMap { id in
            guard let element = elements[id], AX.isEligible(element), let frame = AX.frame(element) else { return nil }
            return (id, frame)
        }
        // Refresh Quartz after AX collection: Stage Manager can transition during enumeration.
        let rendered = try ScreenEnvironment.renderedWindows()
        let displays = try ScreenEnvironment.displays(rendered: rendered)
        return DesktopSnapshot(displays: displays, windows: frames.map {
            WindowSnapshot(id: $0.0, frame: $0.1,
                           isVisible: StageGeometry.isVisible(pid: $0.0.pid, frame: $0.1, rendered: rendered))
        })
    }

    func frame(of window: WindowID) throws -> CGRect {
        guard let element = elements[window], let frame = AX.frame(element) else { throw LayoutError.unavailableWindow }
        return frame
    }

    func resize(_ window: WindowID, to size: CGSize) throws {
        guard AXIsProcessTrusted() else { throw LayoutError.accessibilityRequired }
        guard let element = elements[window] else { throw LayoutError.unavailableWindow }
        try AX.setSize(element, size)
    }

    func place(_ window: WindowID, at frame: CGRect) throws {
        guard AXIsProcessTrusted() else { throw LayoutError.accessibilityRequired }
        guard frame.isUsable, let element = elements[window] else { throw LayoutError.unavailableWindow }
        // Keep the AX object because applications may change window titles during resize.
        try AX.setSize(element, frame.size)
        try AX.setPosition(element, frame.origin)
        try AX.setSize(element, frame.size)
    }
}

@MainActor enum ScreenEnvironment {
    static func renderedWindows() throws -> [RenderedWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { throw LayoutError.unavailableDisplays }
        return info.compactMap { item in
            guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowIsOnscreen as String] as? Bool) == true,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.isUsable else { return nil }
            return RenderedWindow(pid: pid.int32Value, frame: frame)
        }
    }

    static func displays(rendered: [RenderedWindow]) throws -> [Display] {
        let screens = NSScreen.screens
        guard let reference = screens.first else { throw LayoutError.unavailableDisplays }
        let top = reference.frame.maxY
        let base = screens.compactMap { screen -> Display? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: number.uint32Value,
                           frame: Geometry.accessibilityFrame(screen.frame, referenceTop: top),
                           visibleFrame: Geometry.accessibilityFrame(screen.visibleFrame, referenceTop: top))
        }
        let strips = stageStrips(displays: base)
        return base.map { display in
            Display(id: display.id, frame: display.frame, visibleFrame: display.visibleFrame,
                    stageExtent: StageGeometry.extent(on: display, strips: strips, rendered: rendered))
        }
    }

    private static func stageStrips(displays: [Display]) -> [StageStrip] {
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return [] }
        let root = AXUIElementCreateApplication(manager.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var strips: [StageStrip] = []
        var budget = 256
        func visit(_ node: AXUIElement, parent: AXUIElement?, depth: Int) {
            guard depth <= 5, budget > 0 else { return }
            budget -= 1
            if AX.attribute(node, kAXIdentifierAttribute) as? String == "sm.strip", let frame = AX.frame(node) {
                let parentOrigin = parent.flatMap { AX.frame($0)?.origin }
                let display = displays.first { display in
                    if let origin = parentOrigin {
                        return abs(origin.x - display.frame.minX) <= 1 && abs(origin.y - display.frame.minY) <= 1
                    }
                    return false
                } ?? Geometry.display(for: frame, in: displays)
                if let display {
                    strips.append(StageStrip(screenOrigin: display.frame.origin, frame: frame,
                                             buttons: AX.elements(node).compactMap { AX.frame($0) }))
                }
                return
            }
            for child in AX.elements(node) { visit(child, parent: node, depth: depth + 1) }
        }
        visit(root, parent: nil, depth: 0)
        return strips
    }
}
