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

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// A floating block of pixels pasted over the canvas. Resizing scales its pixels
/// with nearest-neighbour sampling, so flat blocks just cover a bigger area.
public struct Patch {
    public var image: CGImage
    public var rect: CGRect

    public init(image: CGImage, rect: CGRect) {
        self.image = image
        self.rect = rect
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
        Handle.allCases.first { h in
            let p = h.point(in: rect)
            return abs(p.x - point.x) <= slop && abs(p.y - point.y) <= slop
        }
    }
}
