import CoreGraphics
import Foundation

public struct ImageExportStyle: Codable, Equatable, Sendable {
    public enum Background: String, CaseIterable, Codable, Sendable { case none, solid, gradient, image }
    public var background: Background = .gradient
    public var color = RGBA(0.82, 0.89, 0.96)
    public var gradientEnd = RGBA(0.96, 0.93, 0.86)
    public var padding: CGFloat = 32
    public var cornerRadius: CGFloat = 12
    public var shadow = true
    public init() {}
}

public enum ImageExportRenderer {
    /// Preview and PNG export share this renderer; `scale` only changes resolution.
    public static func render(_ image: CGImage, style: ImageExportStyle, backgroundImage: CGImage? = nil,
                              scale: CGFloat = 1) -> CGImage? {
        guard scale.isFinite, scale > 0, scale <= 1,
              style.padding.isFinite, style.cornerRadius.isFinite else { return nil }
        if style.background == .image && backgroundImage == nil { return nil }
        let decorated = style.background != .none
        let padding = decorated ? max(0, min(256, style.padding)) : 0
        let width = ceil((CGFloat(image.width) + padding * 2) * scale)
        let height = ceil((CGFloat(image.height) + padding * 2) * scale)
        guard width >= 1, height >= 1, width <= 32768, height <= 32768, width * height <= 100_000_000 else { return nil }
        let ctx = Renderer.makeContext(width: Int(width), height: Int(height))
        ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: scale, y: -scale)
        let bounds = CGRect(x: 0, y: 0, width: width / scale, height: height / scale)
        switch style.background {
        case .none: break
        case .solid:
            ctx.setFillColor(style.color.cgColor); ctx.fill(bounds)
        case .gradient:
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [style.color.cgColor, style.gradientEnd.cgColor] as CFArray,
                                            locations: [0, 1]) else { return nil }
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image:
            if let backgroundImage {
                let factor = max(bounds.width / CGFloat(backgroundImage.width), bounds.height / CGFloat(backgroundImage.height))
                let size = CGSize(width: CGFloat(backgroundImage.width) * factor, height: CGFloat(backgroundImage.height) * factor)
                ctx.interpolationQuality = .high
                Renderer.drawImage(ctx, backgroundImage, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            }
        }
        let content = CGRect(x: padding, y: padding, width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = decorated ? max(0, min(style.cornerRadius, min(content.width, content.height) / 2)) : 0
        let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if decorated && style.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 12, color: CGColor(gray: 0, alpha: 0.25))
            ctx.setFillColor(RGBA.white.cgColor); ctx.addPath(path); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(path); ctx.clip()
        ctx.interpolationQuality = .high
        Renderer.drawImage(ctx, image, in: content)
        return ctx.makeImage()
    }
}
