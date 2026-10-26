import AppKit
import Vision

public enum CaptureVisualRegions {
    public static func detect(image: CGImage, screenRect: CGRect) -> [CGRect] {
        let ratio = min(1, 1800 / CGFloat(max(image.width, image.height)))
        let context = Renderer.makeContext(width: max(1, Int(CGFloat(image.width) * ratio)), height: max(1, Int(CGFloat(image.height) * ratio)))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let thumbnail = context.makeImage() else { return [] }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 80; request.minimumSize = 0.012
        request.minimumAspectRatio = 0.025; request.maximumAspectRatio = 1
        request.minimumConfidence = 0.65; request.quadratureTolerance = 8
        do { try VNImageRequestHandler(cgImage: thumbnail).perform([request]) } catch { return [] }
        return (request.results ?? []).map {
            let r = $0.boundingBox
            return CGRect(x: screenRect.minX + r.minX * screenRect.width,
                          y: screenRect.minY + (1 - r.maxY) * screenRect.height,
                          width: r.width * screenRect.width, height: r.height * screenRect.height)
        }
    }
}
