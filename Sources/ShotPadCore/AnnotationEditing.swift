import CoreGraphics
import Foundation

public enum AnnotationHandle: Equatable {
    case box(Handle)
    case start, end
}

public enum AnnotationEditHit: Equatable {
    case handle(AnnotationHandle)
    case move
}

/// Hit-testing, moving and resizing for annotations that stay editable after being drawn.
public extension Annotation {
    var isEditable: Bool {
        switch kind {
        case .rect, .ellipse, .line, .arrow, .text, .number, .pen, .highlighter: return true
        default: return false
        }
    }

    /// Visual extent of the annotation (stroke included), nil for kinds that are not editable.
    var bounds: CGRect? {
        let t = lineWidth / 2
        switch kind {
        case .rect(let r), .ellipse(let r): return r.insetBy(dx: -t, dy: -t)
        case .line(let p, let q), .arrow(let p, let q): return CGRect.spanning(p, q).insetBy(dx: -t, dy: -t)
        case .text(let s, let o, let size):
            let natural = Renderer.textSize(s, fontSize: size, width: boxWidth, fontName: fontName)
            return CGRect(origin: o, size: CGSize(width: max(textAreaWidth, natural.width), height: max(size * 1.25, natural.height)))
        case .pen(let points), .highlighter(let points):
            guard let first = points.first else { return nil }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -t, dy: -t)
        case .number(_, let c, let d): return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        default: return nil
        }
    }

    /// Handles to show while selected, with their positions.
    var handles: [(AnnotationHandle, CGPoint)] {
        switch kind {
        case .line(let p, let q), .arrow(let p, let q): return [(.start, p), (.end, q)]
        case .number:
            guard let b = bounds else { return [] }
            return [Handle.topLeft, .topRight, .bottomRight, .bottomLeft].map { (.box($0), $0.point(in: b)) }
        default:
            guard let b = bounds else { return [] }
            return Handle.allCases.map { (.box($0), $0.point(in: b)) }
        }
    }

    func handle(at p: CGPoint, slop: CGFloat) -> AnnotationHandle? {
        handles.first { abs($0.1.x - p.x) <= slop && abs($0.1.y - p.y) <= slop }?.0
    }

    /// The active selection owns its entire bounding box, including empty space between strokes.
    func editingHit(at p: CGPoint, slop: CGFloat) -> AnnotationEditHit? {
        if let handle = handle(at: p, slop: slop) { return .handle(handle) }
        return bounds?.contains(p) == true ? .move : nil
    }

    /// True when `p` lands on the drawn shape (the stroke, not the empty inside of an outline).
    func hit(_ p: CGPoint, slop: CGFloat) -> Bool {
        let t = lineWidth / 2 + slop
        switch kind {
        case .rect(let r):
            if cornerRadius > 0 {
                let outer = r.insetBy(dx: -t, dy: -t)
                let radius = min(cornerRadius, min(r.width, r.height) / 2)
                let outerPath = CGPath(roundedRect: outer, cornerWidth: radius + t, cornerHeight: radius + t, transform: nil)
                guard outerPath.contains(p) else { return false }
                if fill != .none { return true }
                let inner = r.insetBy(dx: t, dy: t)
                if inner.width <= 0 || inner.height <= 0 { return true }
                return !CGPath(roundedRect: inner, cornerWidth: max(0, radius - t), cornerHeight: max(0, radius - t), transform: nil).contains(p)
            }
            if fill != .none { return r.insetBy(dx: -t, dy: -t).contains(p) }
            return r.insetBy(dx: -t, dy: -t).contains(p) && !r.insetBy(dx: t, dy: t).contains(p)
        case .ellipse(let r):
            guard r.width > 0, r.height > 0 else { return false }
            let a = r.width / 2, b = r.height / 2
            let n = sqrt(pow((p.x - r.midX) / a, 2) + pow((p.y - r.midY) / b, 2))
            if fill != .none { return n <= 1 + t / min(a, b) }
            return abs(n - 1) * min(a, b) <= t
        case .line(let a, let b), .arrow(let a, let b):
            return Self.distance(from: p, toSegment: a, b) <= t
        case .pen(let points), .highlighter(let points):
            return zip(points, points.dropFirst()).contains { Self.distance(from: p, toSegment: $0.0, $0.1) <= t } || (points.count == 1 && hypot(p.x - points[0].x, p.y - points[0].y) <= t)
        case .text:
            return bounds?.insetBy(dx: -slop, dy: -slop).contains(p) ?? false
        case .number(_, let c, let d):
            return hypot(p.x - c.x, p.y - c.y) <= d / 2 + slop
        default: return false
        }
    }

    mutating func move(by d: CGSize) {
        func sh(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
        switch kind {
        case .rect(let r): kind = .rect(r.offsetBy(dx: d.width, dy: d.height))
        case .ellipse(let r): kind = .ellipse(r.offsetBy(dx: d.width, dy: d.height))
        case .line(let p, let q): kind = .line(sh(p), sh(q))
        case .arrow(let p, let q): kind = .arrow(sh(p), sh(q))
        case .mosaic(let r, let block): kind = .mosaic(r.offsetBy(dx: d.width, dy: d.height), block: block)
        case .blur(let r, let radius): kind = .blur(r.offsetBy(dx: d.width, dy: d.height), radius: radius)
        case .textBox(let s, let r, let background): kind = .textBox(s, rect: r.offsetBy(dx: d.width, dy: d.height), background: background)
        case .text(let s, let o, let size): kind = .text(s, origin: sh(o), fontSize: size)
        case .pen(let points): kind = .pen(points.map(sh))
        case .highlighter(let points): kind = .highlighter(points.map(sh))
        case .number(let n, let c, let dia): kind = .number(n, center: sh(c), diameter: dia)
        }
    }

    /// Inspector edits are independent of the existing mouse-handle resizing rules.
    func settingFrame(_ requested: CGRect) -> Annotation {
        guard let old = bounds, requested.origin.x.isFinite, requested.origin.y.isFinite,
              requested.width.isFinite, requested.height.isFinite else { return self }
        let minimum: CGFloat
        switch kind { case .line, .arrow: minimum = lineWidth; default: minimum = lineWidth + 1 }
        let frame = CGRect(x: requested.minX, y: requested.minY,
                           width: max(minimum, requested.width), height: max(minimum, requested.height))
        var result = self
        switch kind {
        case .rect: result.kind = .rect(frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case .ellipse: result.kind = .ellipse(frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case .line(let p, let q), .arrow(let p, let q):
            let inner = frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let start = CGPoint(x: p.x > q.x ? inner.maxX : inner.minX, y: p.y > q.y ? inner.maxY : inner.minY)
            let end = CGPoint(x: q.x >= p.x ? inner.maxX : inner.minX, y: q.y >= p.y ? inner.maxY : inner.minY)
            if case .line = kind { result.kind = .line(start, end) } else { result.kind = .arrow(start, end) }
        case .pen(let points), .highlighter(let points):
            let transformed = points.map { CGPoint(x: frame.minX + ($0.x - old.minX) * frame.width / max(1, old.width), y: frame.minY + ($0.y - old.minY) * frame.height / max(1, old.height)) }
            if case .pen = kind { result.kind = .pen(transformed) } else { result.kind = .highlighter(transformed) }
        case .text(let text, _, let size):
            let font = max(8, size * frame.height / max(1, old.height))
            if abs(frame.width - old.width) > 0.001 { result.textAreaWidth = frame.width; result.textFixedWidth = frame.width; result.boxWidth = frame.width }
            result.kind = .text(text, origin: frame.origin, fontSize: font)
        case .number(let number, _, _):
            let diameter = max(12, min(frame.width, frame.height))
            result.kind = .number(number, center: CGPoint(x: frame.minX + diameter / 2, y: frame.minY + diameter / 2), diameter: diameter)
        default: break
        }
        return result
    }

    /// Returns `self` (the state at drag start) reshaped by dragging `handle` to `point`.
    func dragged(_ handle: AnnotationHandle, to point: CGPoint) -> Annotation {
        var a = self
        switch (kind, handle) {
        case (.line(_, let q), .start): a.kind = .line(point, q)
        case (.line(let p, _), .end): a.kind = .line(p, point)
        case (.arrow(_, let q), .start): a.kind = .arrow(point, q)
        case (.arrow(let p, _), .end): a.kind = .arrow(p, point)
        case (.rect(let r), .box(let h)): a.kind = .rect(Patch.resized(r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2), handle: h, to: point).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case (.ellipse(let r), .box(let h)): a.kind = .ellipse(Patch.resized(r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2), handle: h, to: point).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case (.number(let n, _, _), .box(let h)):
            guard let b = bounds else { break }
            let o = Self.opposite(h).point(in: b)
            let dx = point.x - o.x, dy = point.y - o.y
            let d = max(12, abs(dx), abs(dy))
            a.kind = .number(n, center: CGPoint(x: o.x + (dx < 0 ? -d : d) / 2, y: o.y + (dy < 0 ? -d : d) / 2), diameter: d)
        case (.pen, .box(let h)), (.highlighter, .box(let h)):
            if let b = bounds { return settingFrame(Patch.resized(b, handle: h, to: point)) }
        case (.text(let s, _, let size), .box(let h)):
            guard let b = bounds else { break }
            let edgeSideways = h == .left || h == .right
            if edgeSideways {
                // side handles re-wrap the text without changing the font size
                let r = Patch.resized(b, handle: h, to: point)
                a.textAreaWidth = max(40, r.width); a.textFixedWidth = a.textAreaWidth; a.boxWidth = a.textAreaWidth
                a.kind = .text(s, origin: CGPoint(x: r.minX, y: b.minY), fontSize: size)
            } else {
                let r = Patch.resized(b, handle: h, to: point)
                let vertical = h == .top || h == .bottom
                let ratio = max(0.1, vertical ? r.height / max(b.height, 1) : r.width / max(b.width, 1))
                let anchor = Self.opposite(h).point(in: b)
                let newSize = max(8, size * ratio)
                let o2 = CGPoint(x: h.movesLeft ? anchor.x - b.width * ratio : b.minX,
                                 y: h.movesTop ? anchor.y - b.height * ratio : b.minY)
                a.textAreaWidth = max(40, textAreaWidth * ratio)
                a.textFixedWidth = textFixedWidth.map { $0 * ratio }; a.boxWidth = boxWidth.map { $0 * ratio }
                a.kind = .text(s, origin: o2, fontSize: newSize)
            }
        default: break
        }
        return a
    }

    private static func opposite(_ h: Handle) -> Handle {
        switch h {
        case .topLeft: return .bottomRight
        case .top: return .bottom
        case .topRight: return .bottomLeft
        case .right: return .left
        case .bottomRight: return .topLeft
        case .bottom: return .top
        case .bottomLeft: return .topRight
        case .left: return .right
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
