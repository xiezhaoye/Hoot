import AppKit
import CoreImage

/// Rasterises a base image plus annotations (and an optional floating patch).
/// Everything works in image pixels with a top-left origin.
public enum Renderer {
    static let ciContext = CIContext()

    public static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Draws `image` upright into `rect` of a context whose y axis already points down.
    public static func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    public static func render(base: CGImage, annotations: [Annotation], patch: Patch? = nil) -> CGImage {
        let w = base.width, h = base.height
        let ctx = makeContext(width: w, height: h)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawImage(ctx, base, in: CGRect(x: 0, y: 0, width: w, height: h))
        for a in annotations { draw(a, in: ctx) }
        if let patch {
            if let hole = patch.vacated {
                ctx.setFillColor(RGBA.white.cgColor)
                ctx.fill(hole.integral)
            }
            ctx.saveGState()
            ctx.interpolationQuality = .none
            drawImage(ctx, patch.image, in: patch.rect.integral)
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    // MARK: - Annotations

    public static func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .rect(let r):
            ctx.stroke(r)
        case .ellipse(let r):
            ctx.strokeEllipse(in: r)
        case .line(let p, let q):
            ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
        case .arrow(let p, let q):
            drawArrow(ctx, from: p, to: q, width: a.lineWidth)
        case .pen(let pts):
            stroke(ctx, pts)
        case .highlighter(let pts):
            ctx.setStrokeColor(CGColor(srgbRed: a.color.r, green: a.color.g, blue: a.color.b, alpha: 0.4))
            ctx.setLineWidth(a.lineWidth * 5)
            ctx.setLineCap(.square)
            stroke(ctx, pts)
        case .mosaic(let r, let block):
            if let snap = ctx.makeImage(), let out = pixelate(snap, rect: r, block: block) {
                drawImage(ctx, out, in: r.integral.clamped(to: CGRect(x: 0, y: 0, width: snap.width, height: snap.height)))
            }
        case .blur(let r, let radius):
            if let snap = ctx.makeImage(), let out = blurred(snap, rect: r, radius: radius) {
                drawImage(ctx, out, in: r.integral.clamped(to: CGRect(x: 0, y: 0, width: snap.width, height: snap.height)))
            }
        case .text(let s, let origin, let size):
            drawText(ctx, s, at: origin, font: .systemFont(ofSize: size, weight: .medium), color: a.color, width: a.boxWidth)
        case .number(let n, let c, let d):
            let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            ctx.fillEllipse(in: r)
            let font = NSFont.boldSystemFont(ofSize: d * 0.6)
            let str = NSAttributedString(string: "\(n)", attributes: [.font: font])
            let sz = str.size()
            drawText(ctx, "\(n)", at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), font: font, color: .white)
        case .textBox(let s, let r, let bg):
            ctx.setFillColor(bg.cgColor)
            ctx.fill(r)
            let size = fitFontSize(s, in: r.size)
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            let sz = NSAttributedString(string: s, attributes: [.font: font]).size()
            drawText(ctx, s, at: CGPoint(x: r.minX + 1, y: r.midY - sz.height / 2), font: font, color: a.color)
        }
    }

    private static func stroke(_ ctx: CGContext, _ pts: [CGPoint]) {
        guard let first = pts.first else { return }
        ctx.move(to: first)
        if pts.count == 1 { ctx.addLine(to: first) }
        pts.dropFirst().forEach { ctx.addLine(to: $0) }
        ctx.strokePath()
    }

    private static func drawArrow(_ ctx: CGContext, from p: CGPoint, to q: CGPoint, width: CGFloat) {
        ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
        let angle = atan2(q.y - p.y, q.x - p.x)
        let head = max(12, width * 4.5)
        for delta in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
            ctx.move(to: q)
            ctx.addLine(to: CGPoint(x: q.x + head * cos(angle + delta), y: q.y + head * sin(angle + delta)))
            ctx.strokePath()
        }
    }

    /// Draws text in a context whose y axis points down.
    static func drawText(_ ctx: CGContext, _ s: String, at p: CGPoint, font: NSFont, color: RGBA, width: CGFloat? = nil) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let str = NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a),
        ])
        if let width {
            str.draw(with: CGRect(x: p.x, y: p.y, width: width, height: 10_000), options: [.usesLineFragmentOrigin])
        } else {
            str.draw(at: p)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Size the text occupies at `fontSize`, wrapped to `width` when given.
    public static func textSize(_ s: String, fontSize: CGFloat, width: CGFloat? = nil) -> CGSize {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)])
        if let width {
            let r = str.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin])
            return CGSize(width: width, height: ceil(r.height))
        }
        let sz = str.size()
        return CGSize(width: ceil(sz.width), height: ceil(sz.height))
    }

    /// Largest font size (≤ 90% of the box height) at which `s` fits the box width.
    public static func fitFontSize(_ s: String, in box: CGSize) -> CGFloat {
        var size = max(8, box.height * 0.9)
        while size > 8 {
            let w = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).size().width
            if w <= box.width { break }
            size -= 1
        }
        return size
    }

    // MARK: - Pixel effects

    public static func pixelate(_ image: CGImage, rect: CGRect, block: Int) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = image.cropping(to: rect.integral.clamped(to: bounds)), block > 0 else { return nil }
        let sw = max(1, crop.width / block), sh = max(1, crop.height / block)
        let small = makeContext(width: sw, height: sh)
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let smallImage = small.makeImage() else { return nil }
        let big = makeContext(width: crop.width, height: crop.height)
        big.interpolationQuality = .none
        big.draw(smallImage, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return big.makeImage()
    }

    public static func blurred(_ image: CGImage, rect: CGRect, radius: Double) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = image.cropping(to: rect.integral.clamped(to: bounds)) else { return nil }
        let input = CIImage(cgImage: crop)
        let out = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        return ciContext.createCGImage(out, from: input.extent)
    }

    /// Most common (coarsely quantised) colour inside `rect` — a good guess at the background behind text.
    public static func dominantColor(in image: CGImage, rect: CGRect) -> RGBA {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = image.cropping(to: rect.integral.clamped(to: bounds)) else { return .white }
        let w = min(crop.width, 48), h = min(crop.height, 24)
        let ctx = makeContext(width: w, height: h)
        ctx.interpolationQuality = .low
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return .white }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var counts: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let i = y * ctx.bytesPerRow + x * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                let c = counts[key] ?? (0, 0, 0, 0)
                counts[key] = (c.n + 1, c.r + r, c.g + g, c.b + b)
            }
        }
        guard let best = counts.values.max(by: { $0.n < $1.n }) else { return .white }
        return RGBA(Double(best.r) / Double(best.n) / 255, Double(best.g) / Double(best.n) / 255,
                    Double(best.b) / Double(best.n) / 255)
    }
}
