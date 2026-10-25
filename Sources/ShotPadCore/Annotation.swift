import CoreGraphics
import Foundation

public struct RGBA: Equatable, Codable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
    public static let red = RGBA(0.95, 0.2, 0.2)
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
}

public enum Tool: String, CaseIterable {
    case select, rect, ellipse, line, arrow, pen, highlighter, mosaic, blur, text, number, crop
}

/// All coordinates are in image pixels with the origin at the top-left.
public struct Annotation: Identifiable {
    public enum Kind {
        case rect(CGRect)
        case ellipse(CGRect)
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case mosaic(CGRect, block: Int)
        case blur(CGRect, radius: Double)
        case text(String, origin: CGPoint, fontSize: CGFloat)
        case number(Int, center: CGPoint, diameter: CGFloat)
        /// Translated text laid over the original; `color` is the text colour.
        case textBox(String, rect: CGRect, background: RGBA)
    }

    public let id = UUID()
    public var kind: Kind
    public var color: RGBA
    public var lineWidth: CGFloat
    /// Wrap width for `.text`; nil means one unwrapped line.
    public var boxWidth: CGFloat?

    public init(_ kind: Kind, color: RGBA = .red, lineWidth: CGFloat = 3) {
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }
}

public extension CGRect {
    static func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func clamped(to bounds: CGRect) -> CGRect { intersection(bounds).isNull ? .zero : intersection(bounds) }
}
