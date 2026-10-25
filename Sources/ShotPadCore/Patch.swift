import CoreGraphics

public enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Position of the handle on `rect` (top-left origin).
    public func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The handle under `point`: a corner or edge midpoint, or any point along an edge (within `slop`).
    public static func hit(in r: CGRect, at p: CGPoint, slop: CGFloat) -> Handle? {
        if let h = allCases.first(where: { h in let q = h.point(in: r); return abs(q.x - p.x) <= slop && abs(q.y - p.y) <= slop }) { return h }
        let inX = p.x >= r.minX - slop && p.x <= r.maxX + slop, inY = p.y >= r.minY - slop && p.y <= r.maxY + slop
        if inX, abs(p.y - r.minY) <= slop { return .top }
        if inX, abs(p.y - r.maxY) <= slop { return .bottom }
        if inY, abs(p.x - r.minX) <= slop { return .left }
        if inY, abs(p.x - r.maxX) <= slop { return .right }
        return nil
    }

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// A floating block of pixels pasted over the canvas. Resizing scales its pixels
/// with nearest-neighbour sampling, so flat blocks just cover a bigger area.
public struct Patch {
    public var image: CGImage
    public var rect: CGRect
    /// Area the pixels were lifted from; it is blanked to white while the patch floats.
    public var vacated: CGRect?

    public init(image: CGImage, rect: CGRect, vacated: CGRect? = nil) {
        self.image = image
        self.rect = rect
        self.vacated = vacated
    }

    /// Dragging `handle` of `original` to `point`. The opposite edge stays fixed and
    /// crossing over it flips the patch's extent rather than collapsing it.
    public static func resized(_ original: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var left = original.minX, right = original.maxX, top = original.minY, bottom = original.maxY
        if handle.movesLeft { left = point.x }
        if handle.movesRight { right = point.x }
        if handle.movesTop { top = point.y }
        if handle.movesBottom { bottom = point.y }
        var r = CGRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
        r.size.width = max(r.width, 1)
        r.size.height = max(r.height, 1)
        return r
    }

    /// The handle under `point` (within `slop` pixels), if any.
    public func hitHandle(at point: CGPoint, slop: CGFloat) -> Handle? {
        Handle.hit(in: rect, at: point, slop: slop)
    }
}
