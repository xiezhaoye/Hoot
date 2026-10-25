import CoreGraphics

/// The fixed-size white canvas every captured screenshot is placed on (top-left); it grows only if the shot is larger.
public enum Board {
    /// An empty white board.
    public static func blank(size: CGSize) -> CGImage? {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    public static func make(placing image: CGImage, size: CGSize) -> CGImage {
        let w = max(Int(size.width), image.width), h = max(Int(size.height), image.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext origin is bottom-left, the shot goes to the visual top-left
        ctx.draw(image, in: CGRect(x: 0, y: h - image.height, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
