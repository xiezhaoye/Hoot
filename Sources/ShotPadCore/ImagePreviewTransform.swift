import CoreGraphics

/// Preview geometry is independent of export pixels: fitting, panning and zooming never resample the image.
public struct ImagePreviewTransform {
    public var frame: CGRect
    public let imageSize: CGSize
    public var pixelsPerPoint: CGFloat { imageSize.width / frame.width }

    public init(imageSize: CGSize, around anchor: CGRect, within viewport: CGRect, nativeScale: CGFloat) {
        self.imageSize = imageSize
        let scale = min(1 / max(0.01, nativeScale), viewport.width / imageSize.width, viewport.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        frame = CGRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        clamp(to: viewport)
    }

    public func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) * pixelsPerPoint, y: (point.y - frame.minY) * pixelsPerPoint)
    }
    public func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x / pixelsPerPoint, y: frame.minY + point.y / pixelsPerPoint)
    }
    public mutating func move(to origin: CGPoint, within viewport: CGRect) { frame.origin = origin; clamp(to: viewport) }
    public mutating func zoom(by factor: CGFloat, at anchor: CGPoint, within viewport: CGRect) {
        let imageAnchor = imagePoint(anchor)
        let fit = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let scale = max(fit * 0.25, min(4, frame.width / imageSize.width * factor))
        frame = CGRect(x: anchor.x - imageAnchor.x * scale, y: anchor.y - imageAnchor.y * scale,
                       width: imageSize.width * scale, height: imageSize.height * scale)
        clamp(to: viewport)
    }
    public mutating func resize(_ handle: Handle, to point: CGPoint, from original: CGRect, within viewport: CGRect) {
        let anchor = CGPoint(x: handle.movesLeft ? original.maxX : handle.movesRight ? original.minX : original.midX,
                             y: handle.movesTop ? original.maxY : handle.movesBottom ? original.minY : original.midY)
        let dx = (point.x - anchor.x) * (handle.movesLeft ? -1 : 1)
        let dy = (point.y - anchor.y) * (handle.movesTop ? -1 : 1)
        let ratio: CGFloat
        if handle == .left || handle == .right { ratio = dx / original.width }
        else if handle == .top || handle == .bottom { ratio = dy / original.height }
        else { ratio = (dx * original.width + dy * original.height) / (original.width * original.width + original.height * original.height) }
        let scale = max(0.05, ratio)
        let width = original.width * scale, height = original.height * scale
        frame = CGRect(x: handle.movesLeft ? anchor.x - width : handle.movesRight ? anchor.x : anchor.x - width / 2,
                       y: handle.movesTop ? anchor.y - height : handle.movesBottom ? anchor.y : anchor.y - height / 2,
                       width: width, height: height)
        clamp(to: viewport)
    }
    private mutating func clamp(to viewport: CGRect) {
        func axis(_ value: CGFloat, _ length: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
            min(max(value, min(start, end - length)), max(start, end - length))
        }
        frame.origin.x = axis(frame.minX, frame.width, viewport.minX, viewport.maxX)
        frame.origin.y = axis(frame.minY, frame.height, viewport.minY, viewport.maxY)
    }
}
