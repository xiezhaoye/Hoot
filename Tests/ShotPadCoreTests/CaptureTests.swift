import XCTest
import AppKit
@testable import ShotPadCore

final class CaptureTests: XCTestCase {
    func testCoordinatesAcrossDisplaysOnLeftAndAbovePrimary() {
        let primaryHeight: CGFloat = 900
        for screen in [CGRect(x: -1440, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 900, width: 1440, height: 900)] {
            let point = CaptureGeometry.global(CGPoint(x: 80, y: 120), screen: screen, primaryHeight: primaryHeight)
            let local = CaptureGeometry.local(CGRect(origin: point, size: CGSize(width: 40, height: 60)), screen: screen, primaryHeight: primaryHeight)
            XCTAssertEqual(local, CGRect(x: 80, y: 120, width: 40, height: 60))
        }
    }
    func testSmallestControlThenContainingPanelAndWindow() {
        let window = CGRect(x: 0, y: 0, width: 900, height: 600)
        let panel = CGRect(x: 20, y: 20, width: 300, height: 500)
        let button = CGRect(x: 40, y: 40, width: 80, height: 30)
        let result = CaptureGeometry.candidates(at: CGPoint(x: 60, y: 50), window: window, regions: [panel, button, button.offsetBy(dx: 0.5, dy: 0.5)])
        XCTAssertEqual(result, [button, panel, window])
    }
    func testRearWindowAndOverlappingNeighboursDoNotLeakThrough() {
        let front = CGRect(x: 100, y: 100, width: 400, height: 400)
        let rear = CGRect(x: 0, y: 0, width: 900, height: 600)
        let a = CGRect(x: 120, y: 120, width: 80, height: 40)
        let neighbour = CGRect(x: 130, y: 110, width: 90, height: 60)
        let result = CaptureGeometry.candidates(at: CGPoint(x: 150, y: 140), window: front, regions: [rear, a, neighbour])
        XCTAssertEqual(result, [a, front])
        XCTAssertTrue(CaptureGeometry.candidates(at: .zero, window: front, regions: [rear]).isEmpty)
    }
    func testRoundedPNGHasTransparentCornersAndKeepsDimensions() {
        let output = CaptureGeometry.rounded(solid(80, 60, .red), radius: 16)
        XCTAssertEqual(output.width, 80); XCTAssertEqual(output.height, 60)
        let ctx = Renderer.makeContext(width: 80, height: 60)
        ctx.draw(output, in: CGRect(x: 0, y: 0, width: 80, height: 60))
        let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * 60)
        XCTAssertEqual(bytes[3], 0)
        XCTAssertEqual(bytes[30 * ctx.bytesPerRow + 40 * 4 + 3], 255)
        XCTAssertEqual(bytes[40 * 4 + 3], 255)
    }
    func testRadiusZeroAndExcessiveRadiusAreSafe() {
        let source = solid(40, 20, .black)
        XCTAssertTrue(CaptureGeometry.rounded(source, radius: 0) === source)
        XCTAssertTrue(CaptureGeometry.rounded(source, radius: .nan) === source)
        XCTAssertEqual(CaptureGeometry.rounded(source, radius: 500).width, 40)
    }
    func testVisualFallbackDetectsSyntheticPanels() {
        let ctx = Renderer.makeContext(width: 900, height: 600)
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        ctx.setFillColor(RGBA.white.cgColor); ctx.setStrokeColor(RGBA.black.cgColor); ctx.setLineWidth(3)
        ctx.addRect(CGRect(x: 80, y: 100, width: 300, height: 360)); ctx.drawPath(using: .fillStroke)
        ctx.addRect(CGRect(x: 500, y: 180, width: 240, height: 180)); ctx.drawPath(using: .fillStroke)
        let detected = CaptureVisualRegions.detect(image: ctx.makeImage()!, screenRect: CGRect(x: -900, y: 0, width: 900, height: 600))
        XCTAssertTrue(detected.contains { abs($0.minX + 820) < 8 && abs($0.width - 300) < 8 }, "\(detected)")
        XCTAssertTrue(detected.contains { abs($0.minX + 400) < 8 && abs($0.width - 240) < 8 }, "\(detected)")
    }
}
