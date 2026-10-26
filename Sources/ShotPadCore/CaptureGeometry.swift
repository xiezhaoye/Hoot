import Foundation
import CoreGraphics

/// CGWindow and accessibility rectangles use screen points with a top-left origin.
public enum CaptureGeometry {
    public static func local(_ rect: CGRect, screen: CGRect, primaryHeight: CGFloat) -> CGRect {
        rect.offsetBy(dx: -screen.minX, dy: -(primaryHeight - screen.maxY))
    }
    public static func global(_ point: CGPoint, screen: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: screen.minX + point.x, y: primaryHeight - screen.maxY + point.y)
    }
    /// Clip to the frontmost window and form a stable small-to-large ancestor chain.
    public static func candidates(at point: CGPoint, window: CGRect, regions: [CGRect]) -> [CGRect] {
        guard window.contains(point) else { return [] }
        var result: [CGRect] = []
        for raw in regions + [window] {
            guard !raw.isNull, raw.minX.isFinite, raw.minY.isFinite, raw.width.isFinite, raw.height.isFinite, raw.width >= 10, raw.height >= 10 else { continue }
            let r = raw.intersection(window)
            guard !r.isNull, r.contains(point), r.width >= 10, r.height >= 10,
                  r.width * r.height >= raw.width * raw.height * 0.9 else { continue }
            if !result.contains(where: { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }) { result.append(r) }
        }
        result.sort { $0.width * $0.height < $1.width * $1.height }
        var hierarchy: [CGRect] = []
        for r in result {
            if let smaller = hierarchy.last, !r.insetBy(dx: -2, dy: -2).contains(smaller) { continue }
            hierarchy.append(r)
        }
        return hierarchy
    }
    public static func rounded(_ image: CGImage, radius: CGFloat) -> CGImage {
        guard radius.isFinite, radius > 0 else { return image }
        let r = min(radius, CGFloat(min(image.width, image.height)) / 2)
        let ctx = Renderer.makeContext(width: image.width, height: image.height)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setShouldAntialias(true)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip(); ctx.draw(image, in: bounds)
        return ctx.makeImage()!
    }
}
