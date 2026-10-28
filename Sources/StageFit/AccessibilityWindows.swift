import AppKit
import ApplicationServices
import StageFitCore

struct AccessibilityFailure: LocalizedError {
    let operation: String
    let code: AXError
    var errorDescription: String? { "\(operation) failed (Accessibility \(code.rawValue))." }
}

enum AX {
    // Undocumented, optional bridge used by macOS window managers to match AX windows
    // with Stage Manager's AXWindowsIDs. Missing support falls back to unique geometry.
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowNumber: WindowNumber? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowNumber.self)
    }()

    static func number(_ element: AXUIElement) -> CGWindowID? {
        var number: CGWindowID = 0
        if let windowNumber, windowNumber(element, &number) == .success, number != 0 { return number }
        return nil
    }
    static func size(_ element: AXUIElement, attributes: [String]) -> CGSize? {
        for name in attributes {
            guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { continue }
            var size = CGSize.zero
            if AXValueGetValue(value as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 { return size }
        }
        return nil
    }
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
    enum Readiness { case ready, pending, excluded, closed }
    static func readiness(_ element: AXUIElement) -> Readiness {
        var subrole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if status == .invalidUIElement { return .closed }
        if status == .attributeUnsupported { return .excluded }
        guard status == .success, let subrole else { return .pending }
        guard subrole as? String == kAXStandardWindowSubrole,
              attribute(element, kAXMinimizedAttribute) as? Bool != true,
              attribute(element, "AXFullScreen") as? Bool != true else { return .excluded }
        for name in [kAXSizeAttribute, kAXPositionAttribute] {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            if result == .invalidUIElement { return .closed }
            guard result == .success else { return .pending }
            if !settable.boolValue { return .excluded }
        }
        return .ready
    }

}

actor AccessibilityWindows: WindowAccess {
    private var elements: [WindowID: AXUIElement] = [:]
    private var serial: UInt64 = 0
    private var numbers: [WindowID: UInt32] = [:]
    nonisolated static let excluded = Set(["com.raycast.macos", "com.apple.dock", "com.apple.WindowManager",
                               "com.apple.controlcenter", "com.apple.notificationcenterui",
                               "com.pitonmert.StageFit"])

    @MainActor static func isEligible(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && app.activationPolicy == .regular &&
        !excluded.contains(app.bundleIdentifier ?? "") && app.processIdentifier != getpid()
    }

    func id(for element: AXUIElement) -> WindowID {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let existing = elements.first(where: { $0.key.pid == pid && CFEqual($0.value, element) }) { return existing.key }
        serial += 1
        let id = WindowID(pid: pid, serial: serial)
        AXUIElementSetMessagingTimeout(element, 0.5)
        elements[id] = element
        numbers[id] = AX.number(element)
        return id
    }

    func windows(pid: Int32) -> Set<WindowID> {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Do not interpret a transient AX failure as all of an app's windows closing.
        guard let list = AX.attribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
            return Set(elements.keys.filter { $0.pid == pid })
        }
        let ids = Set(list.map { id(for: $0) })
        elements = elements.filter { $0.key.pid != pid || ids.contains($0.key) }
        return ids
    }

    func remove(pid: pid_t) {
        elements = elements.filter { $0.key.pid != pid }
        numbers = numbers.filter { $0.key.pid != pid }
    }

    func capture(only ids: Set<WindowID>?) async throws -> CaptureResult {
        guard AXIsProcessTrusted() else { throw LayoutError.accessibilityRequired }
        let environment = try await AppEnvironment.read()
        if environment.locked { return CaptureResult(desktop: .init(displays: [], windows: [])) }
        let initialRendered = try ScreenEnvironment.renderedWindows()
        let (displays, rawGroups) = ScreenEnvironment.environment(
            displays: environment.displays, managerPID: environment.managerPID, rendered: initialRendered)
        let server = ScreenEnvironment.serverWindows()
        var pids = Set(environment.applications.keys)
        var groupNumbers: Set<UInt32> = []
        var targetDisplays: Set<UInt32> = []
        if let ids {
            var requestedFrames: [WindowID: CGRect] = [:]
            for id in ids {
                guard let element = elements[id], let frame = AX.frame(element) else { continue }
                requestedFrames[id] = frame
                if numbers[id] == nil {
                    let matches = server.filter { $0.pid == id.pid && Geometry.near($0.frame, frame) }
                    if matches.count == 1 { numbers[id] = matches[0].number }
                }
            }
            targetDisplays = Set(requestedFrames.values.compactMap { Geometry.display(for: $0, in: displays)?.id })
            let selection = WindowCaptureSelection(requested: ids, frames: requestedFrames,
                numbers: numbers, groups: rawGroups, server: server, rendered: initialRendered, displays: displays)
            groupNumbers = selection.numbers
            pids = selection.pids
            pids.formIntersection(environment.applications.keys)
        } else {
            elements = elements.filter { pids.contains($0.key.pid) }
        }
        var candidates: Set<WindowID> = []
        for pid in pids {
            try Task.checkCancellation()
            candidates.formUnion(windows(pid: pid))
        }
        numbers = numbers.filter { elements[$0.key] != nil }
        var retryable: Set<WindowID> = []
        var frames: [(WindowID, CGRect)] = []
        for id in candidates {
            try Task.checkCancellation()
            guard let element = elements[id] else { continue }
            var readFrame: CGRect?
            if let ids, !ids.contains(id) {
                if !groupNumbers.isEmpty {
                    if numbers[id] == nil, let frame = AX.frame(element) {
                        readFrame = frame
                        let matches = server.filter { $0.pid == id.pid && Geometry.near($0.frame, frame) }
                        if matches.count == 1 { numbers[id] = matches[0].number }
                    }
                    guard numbers[id].map({ groupNumbers.contains($0) }) == true else { continue }
                } else {
                    guard let frame = AX.frame(element),
                          Geometry.display(for: frame, in: displays).map({ targetDisplays.contains($0.id) }) == true,
                          StageGeometry.isVisible(pid: id.pid, frame: frame, rendered: initialRendered) else { continue }
                    readFrame = frame
                }
            }
            switch AX.readiness(element) {
            case .pending: retryable.insert(id)
            case .excluded, .closed: continue
            case .ready:
                if let frame = readFrame ?? AX.frame(element) { frames.append((id, frame)) }
                else { retryable.insert(id) }
            }
        }
        let rendered = try ScreenEnvironment.renderedWindows()
        let snapshots = frames.map {
            WindowSnapshot(id: $0.0, frame: $0.1,
                isVisible: StageGeometry.isVisible(pid: $0.0.pid, frame: $0.1, rendered: rendered),
                bundleIdentifier: environment.applications[$0.0.pid])
        }
        let thumbnails = Set(server.filter { $0.pid == environment.managerPID }.map(\.number))
        let hiddenGroups = StageGroupResolver.resolve(rawGroups, windows: snapshots,
            serverWindows: server, numbers: numbers, ignoredNumbers: thumbnails)
        return CaptureResult(desktop: DesktopSnapshot(displays: displays, windows: snapshots,
            hiddenGroups: hiddenGroups), retryableIDs: retryable)
    }

    func visibility() throws -> [RenderedWindow] { try ScreenEnvironment.renderedWindows() }

    func frame(of window: WindowID) throws -> CGRect {
        guard let element = elements[window], let frame = AX.frame(element) else { throw LayoutError.unavailableWindow }
        return frame
    }

    func sizeConstraints(of window: WindowID) -> WindowSizeConstraints {
        guard let element = elements[window] else { return .init() }
        return WindowSizeConstraints(minimum: AX.size(element, attributes: ["AXMinSize", "AXMinimumSize"]),
            maximum: AX.size(element, attributes: ["AXMaxSize", "AXMaximumSize"]))
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
        guard let current = AX.frame(element) else { throw LayoutError.unavailableWindow }
        let move = abs(current.minX - frame.minX) > 1 || abs(current.minY - frame.minY) > 1
        let resize = abs(current.width - frame.width) > 1 || abs(current.height - frame.height) > 1
        // Shrink before moving a large window; move before growing so the old
        // screen edge cannot clamp the requested final size.
        if resize, frame.width <= current.width, frame.height <= current.height {
            try AX.setSize(element, frame.size)
            if move { try AX.setPosition(element, frame.origin) }
        } else {
            if move { try AX.setPosition(element, frame.origin) }
            if resize || move { try AX.setSize(element, frame.size) }
        }
    }
}

enum ScreenEnvironment {
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

    static func serverWindows() -> [ServerWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ServerWindow(number: number.uint32Value, pid: pid.int32Value, frame: frame)
        }
    }

    static func environment(displays base: [Display], managerPID: Int32?, rendered: [RenderedWindow]) -> (displays: [Display], groups: [[UInt32]]) {
        let strips = stageStrips(displays: base, managerPID: managerPID)
        let displays = base.map { display in
            Display(id: display.id, frame: display.frame, visibleFrame: display.visibleFrame,
                    stageExtent: StageGeometry.extent(on: display, strips: strips, rendered: rendered))
        }
        return (displays, strips.flatMap(\.windowGroups))
    }

    private static func stageStrips(displays: [Display], managerPID: Int32?) -> [StageStrip] {
        guard let managerPID else { return [] }
        let root = AXUIElementCreateApplication(managerPID)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var strips: [StageStrip] = []
        var budget = 256
        func visit(_ node: AXUIElement, parent: AXUIElement?, depth: Int) {
            guard depth <= 5, budget > 0, !Task.isCancelled else { return }
            budget -= 1
            AXUIElementSetMessagingTimeout(node, 0.2)
            if AX.attribute(node, kAXIdentifierAttribute) as? String == "sm.strip", let frame = AX.frame(node) {
                let parentOrigin = parent.flatMap { AX.frame($0)?.origin }
                let display = displays.first { display in
                    if let origin = parentOrigin {
                        return abs(origin.x - display.frame.minX) <= 1 && abs(origin.y - display.frame.minY) <= 1
                    }
                    return false
                } ?? Geometry.display(for: frame, in: displays)
                if let display {
                    let buttons = Array(AX.elements(node).prefix(budget))
                    budget -= buttons.count
                    for button in buttons { AXUIElementSetMessagingTimeout(button, 0.2) }
                    strips.append(StageStrip(screenOrigin: display.frame.origin, frame: frame,
                                             buttons: buttons.compactMap { AX.frame($0) },
                                             windowGroups: buttons.compactMap {
                        (AX.attribute($0, "AXWindowsIDs") as? [NSNumber])?.map(\.uint32Value)
                    }))
                }
                return
            }
            for child in AX.elements(node) { visit(child, parent: node, depth: depth + 1) }
        }
        visit(root, parent: nil, depth: 0)
        return strips
    }
}

private struct AppEnvironment: Sendable {
    let displays: [Display]
    let applications: [Int32: String]
    let managerPID: Int32?
    let locked: Bool

    @MainActor static func read() throws -> AppEnvironment {
        let screens = NSScreen.screens
        guard let reference = screens.first else { throw LayoutError.unavailableDisplays }
        let displays = screens.compactMap { screen -> Display? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: number.uint32Value,
                frame: Geometry.accessibilityFrame(screen.frame, referenceTop: reference.frame.maxY),
                visibleFrame: Geometry.accessibilityFrame(screen.visibleFrame, referenceTop: reference.frame.maxY))
        }
        let apps = NSWorkspace.shared.runningApplications
        let eligible = apps.filter(AccessibilityWindows.isEligible)
        return AppEnvironment(displays: displays,
            applications: Dictionary(uniqueKeysWithValues: eligible.map { ($0.processIdentifier, $0.bundleIdentifier ?? "unknown") }),
            managerPID: apps.first { $0.bundleIdentifier == "com.apple.WindowManager" }?.processIdentifier,
            locked: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow")
    }
}
