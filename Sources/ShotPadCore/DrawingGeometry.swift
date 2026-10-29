import CoreGraphics

public enum DrawingGeometry {
    /// Shift on a rectangle / ellipse: the far corner moves so the box is a square (circle). `limit` keeps it inside a region.
    public static func squareEndpoint(from start: CGPoint, to end: CGPoint, within limit: CGRect? = nil) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        var side = max(abs(dx), abs(dy))
        if let r = limit {
            side = min(side, dx < 0 ? start.x - r.minX : r.maxX - start.x, dy < 0 ? start.y - r.minY : r.maxY - start.y)
            side = max(0, side)
        }
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    /// Shift on a line / arrow: the direction snaps to the nearest multiple of 45° (horizontal, vertical or diagonal).
    public static func snappedEndpoint(from start: CGPoint, to end: CGPoint, within limit: CGRect? = nil) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        var length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let ux = cos(angle), uy = sin(angle)
        if let r = limit {
            if abs(ux) > 1e-9 { length = min(length, ((ux < 0 ? r.minX : r.maxX) - start.x) / ux) }
            if abs(uy) > 1e-9 { length = min(length, ((uy < 0 ? r.minY : r.maxY) - start.y) / uy) }
            length = max(0, length)
        }
        let x = abs(ux) < 1e-9 ? start.x : start.x + ux * length, y = abs(uy) < 1e-9 ? start.y : start.y + uy * length
        return CGPoint(x: x, y: y)
    }
}
