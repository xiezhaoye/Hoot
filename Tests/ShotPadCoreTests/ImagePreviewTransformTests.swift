import XCTest
@testable import ShotPadCore

final class ImagePreviewTransformTests: XCTestCase {
    func testLongImageFitsWithoutChangingPixelDimensionsAndCoordinatesRoundtrip() {
        let viewport = CGRect(x: 24, y: 72, width: 752, height: 456)
        let size = CGSize(width: 1080, height: 10000)
        let presentation = ImagePreviewTransform(imageSize: size, around: viewport, within: viewport, nativeScale: 2)
        XCTAssertTrue(viewport.insetBy(dx: -0.01, dy: -0.01).contains(presentation.frame))
        XCTAssertEqual(presentation.frame.width / presentation.frame.height, 0.108, accuracy: 0.00001)
        XCTAssertEqual(presentation.imageSize, size)
        for point in [CGPoint.zero, CGPoint(x: 540, y: 5000), CGPoint(x: 1080, y: 10000)] {
            let restored = presentation.imagePoint(presentation.viewPoint(point))
            XCTAssertEqual(restored.x, point.x, accuracy: 0.00001)
            XCTAssertEqual(restored.y, point.y, accuracy: 0.00001)
        }
    }

    func testZoomKeepsImagePointUnderAnchorAndPanCanReachLongImageEnds() {
        let viewport = CGRect(x: 24, y: 72, width: 752, height: 456)
        var p = ImagePreviewTransform(imageSize: CGSize(width: 1080, height: 10000), around: viewport, within: viewport, nativeScale: 2)
        let anchor = CGPoint(x: viewport.midX, y: viewport.midY), pixel = p.imagePoint(anchor)
        p.zoom(by: 4, at: anchor, within: viewport)
        XCTAssertEqual(p.imagePoint(anchor).x, pixel.x, accuracy: 0.00001)
        XCTAssertEqual(p.imagePoint(anchor).y, pixel.y, accuracy: 0.00001)
        p.move(to: CGPoint(x: -100000, y: -100000), within: viewport)
        XCTAssertEqual(p.frame.maxY, viewport.maxY, accuracy: 0.00001)
        p.move(to: CGPoint(x: 100000, y: 100000), within: viewport)
        XCTAssertEqual(p.frame.minY, viewport.minY, accuracy: 0.00001)
        XCTAssertEqual(p.imageSize, CGSize(width: 1080, height: 10000))
    }

    func testEveryResizeHandleKeepsAspectRatioAndOriginalResolution() {
        let viewport = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        for h in Handle.allCases {
            var p = ImagePreviewTransform(imageSize: CGSize(width: 400, height: 200), around: CGRect(x: 700, y: 700, width: 400, height: 200), within: viewport, nativeScale: 1)
            let r = p.frame
            let anchor = CGPoint(x: h.movesLeft ? r.maxX : h.movesRight ? r.minX : r.midX,
                                 y: h.movesTop ? r.maxY : h.movesBottom ? r.minY : r.midY)
            let point = h.point(in: r)
            let end = CGPoint(x: anchor.x + (point.x - anchor.x) * 1.25, y: anchor.y + (point.y - anchor.y) * 1.25)
            p.resize(h, to: end, from: r, within: viewport)
            XCTAssertEqual(p.frame.width, 500, accuracy: 0.001)
            XCTAssertEqual(p.frame.height, 250, accuracy: 0.001)
            XCTAssertEqual(p.imageSize, CGSize(width: 400, height: 200))
        }
    }
}
