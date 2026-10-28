import Foundation

enum LayoutRule {
    case single, pair

    static func ordered(_ windows: [WindowSnapshot]) throws -> (LayoutRule, [WindowSnapshot]) {
        let spatial = windows.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.id.pid != $1.id.pid { return $0.id.pid < $1.id.pid }
            return $0.id.serial < $1.id.serial
        }
        if windows.count == 1 { return (.single, spatial) }
        if windows.count == 2 { return (.pair, spatial) }
        throw LayoutError.tooManyWindows
    }

    func plan(_ windows: [WindowSnapshot], in area: CGRect, gap: CGFloat,
              constraints: [WindowID: WindowSizeConstraints]) throws -> [(WindowID, CGRect)] {
        let limits = windows.map { constraints[$0.id] ?? .init() }
        let minimums = limits.map { max(1, $0.minimum?.width ?? 1) }
        let required = minimums.reduce(0, +) + CGFloat(windows.count - 1) * gap
        guard required <= area.width + 1 else {
            throw LayoutError.widthDoesNotFit(required: required, available: area.width)
        }
        guard limits.allSatisfy({ ($0.minimum?.height ?? 1) <= area.height + 1 }) else {
            throw self == .single ? LayoutError.rejectedFrame : LayoutError.pairDoesNotFit
        }
        var frames: [CGRect]
        switch self {
        case .single:
            frames = [CGRect(origin: area.origin, size: CGSize(
                width: min(area.width, limits[0].maximum?.width ?? area.width), height: area.height))]
        case .pair:
            frames = try Geometry.pair(in: area, gap: gap,
                minimumLeft: minimums[0], minimumRight: minimums[1],
                maximumLeft: limits[0].maximum?.width ?? .infinity,
                maximumRight: limits[1].maximum?.width ?? .infinity)
        }
        for slot in frames.indices {
            frames[slot].size.height = min(area.height, limits[slot].maximum?.height ?? area.height)
            guard frames[slot].isUsable else { throw LayoutError.insufficientSpace }
        }
        return Array(zip(windows.map(\.id), frames))
    }
}
