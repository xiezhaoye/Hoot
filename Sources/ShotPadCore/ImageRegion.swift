import CoreGraphics

public enum ImageRegion {
    /// Image coordinates use a top-left origin. Areas outside the source become white paper.
    public static func extract(_ image: CGImage, rect: CGRect) -> CGImage? {
        let r = rect.integral
        guard r.width.isFinite, r.height.isFinite, r.minX.isFinite, r.minY.isFinite,
              r.width >= 1, r.height >= 1, r.width <= 32768, r.height <= 32768,
              r.width * r.height <= 100_000_000 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if bounds.contains(r) { return image.cropping(to: r) }
        let ctx = Renderer.makeContext(width: Int(r.width), height: Int(r.height))
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(origin: .zero, size: r.size))
        ctx.translateBy(x: 0, y: r.height); ctx.scaleBy(x: 1, y: -1)
        Renderer.drawImage(ctx, image, in: bounds.offsetBy(dx: -r.minX, dy: -r.minY))
        return ctx.makeImage()
    }

    /// Excludes transparent pixels and the white paper around visible content.
    public static func contentBounds(in image: CGImage) -> CGRect? {
        let ctx = Renderer.makeContext(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
        var left = image.width, top = image.height, right = -1, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = y * ctx.bytesPerRow + x * 4, alpha = bytes[i + 3]
                if alpha > 0 && (bytes[i] < alpha || bytes[i + 1] < alpha || bytes[i + 2] < alpha) {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
