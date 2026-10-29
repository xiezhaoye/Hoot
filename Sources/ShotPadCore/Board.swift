import CoreGraphics

/// The fixed-size white canvas every captured screenshot is placed on (top-left); it grows (with a margin) if the shot is larger.
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

    /// Breathing room kept around a shot that is larger than the default board.
    public static let margin: CGFloat = 1.2

    /// The default size, or — per axis — the shot's size plus a margin when the shot would not fit comfortably.
    public static func size(for shot: CGSize, default size: CGSize) -> CGSize {
        func axis(_ board: CGFloat, _ shot: CGFloat) -> CGFloat { shot > board ? (shot * margin).rounded(.up) : board }
        return CGSize(width: axis(size.width, shot.width), height: axis(size.height, shot.height))
    }

    public static func make(placing image: CGImage, size: CGSize) -> CGImage {
        let fitted = Self.size(for: CGSize(width: image.width, height: image.height), default: size)
        let w = Int(fitted.width), h = Int(fitted.height)
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
