import AppKit
import ShotPadCore

/// 8x pixel magnifier with grid and crosshair, drawn next to the cursor in a flipped view.
enum Magnifier {
    static let cells = 15
    static let zoom: CGFloat = 8
    static var side: CGFloat { CGFloat(cells) * zoom }

    /// `pixel` is the cursor position in image pixels; `cursor` the same spot in view coordinates.
    static func draw(in ctx: CGContext, image: CGImage, pixel: CGPoint, cursor: CGPoint, bounds: CGRect, info: String) {
        let cx = Int(pixel.x.rounded(.down)), cy = Int(pixel.y.rounded(.down))
        let infoH: CGFloat = 20
        var box = CGRect(x: cursor.x + 22, y: cursor.y + 22, width: side, height: side + infoH)
        if box.maxX > bounds.maxX - 4 { box.origin.x = cursor.x - 22 - box.width }
        if box.maxY > bounds.maxY - 4 { box.origin.y = cursor.y - 22 - box.height }
        box.origin.x = max(bounds.minX + 4, box.origin.x)
        box.origin.y = max(bounds.minY + 4, box.origin.y)
        let view = CGRect(x: box.minX, y: box.minY, width: side, height: side)

        ctx.saveGState()
        NSColor.black.setFill()
        box.fill()
        ctx.clip(to: view)
        let half = cells / 2
        let src = CGRect(x: cx - half, y: cy - half, width: cells, height: cells)
        let visible = src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isEmpty, let sub = image.cropping(to: visible) {
            ctx.interpolationQuality = .none
            let dest = CGRect(x: view.minX + (visible.minX - src.minX) * zoom, y: view.minY + (visible.minY - src.minY) * zoom,
                              width: visible.width * zoom, height: visible.height * zoom)
            Renderer.drawImage(ctx, sub, in: dest)
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        for i in 0...cells {
            let o = CGFloat(i) * zoom
            ctx.move(to: CGPoint(x: view.minX + o, y: view.minY)); ctx.addLine(to: CGPoint(x: view.minX + o, y: view.maxY))
            ctx.move(to: CGPoint(x: view.minX, y: view.minY + o)); ctx.addLine(to: CGPoint(x: view.maxX, y: view.minY + o))
        }
        ctx.strokePath()
        // crosshair lines through the centre cell, plus an outline of that cell
        let centre = CGRect(x: view.minX + CGFloat(half) * zoom, y: view.minY + CGFloat(half) * zoom, width: zoom, height: zoom)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: view.minX, y: centre.midY)); ctx.addLine(to: CGPoint(x: view.maxX, y: centre.midY))
        ctx.move(to: CGPoint(x: centre.midX, y: view.minY)); ctx.addLine(to: CGPoint(x: centre.midX, y: view.maxY))
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(centre.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        NSColor.white.setStroke()
        NSBezierPath(rect: view.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        (info as NSString).draw(at: CGPoint(x: box.minX + 4, y: view.maxY + 3), withAttributes: attrs)
    }
}
