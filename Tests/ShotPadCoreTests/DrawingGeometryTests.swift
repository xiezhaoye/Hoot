import XCTest
@testable import ShotPadCore

final class DrawingGeometryTests: XCTestCase {
    func testSquareKeepsLongerSideAndDirection() {
        let e = DrawingGeometry.squareEndpoint(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: -5))
        XCTAssertEqual(e.x, 40, accuracy: 1e-9); XCTAssertEqual(e.y, -20, accuracy: 1e-9)
    }

    func testSquareStaysInsideLimit() {
        let e = DrawingGeometry.squareEndpoint(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 30), within: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(e.x, 50, accuracy: 1e-9); XCTAssertEqual(e.y, 50, accuracy: 1e-9)
    }

    func testLineSnapsToAxesAndDiagonals() {
        let o = CGPoint(x: 100, y: 100)
        let h = DrawingGeometry.snappedEndpoint(from: o, to: CGPoint(x: 160, y: 108))
        XCTAssertEqual(h.y, 100, accuracy: 1e-9); XCTAssertGreaterThan(h.x, 150)
        let v = DrawingGeometry.snappedEndpoint(from: o, to: CGPoint(x: 95, y: 20))
        XCTAssertEqual(v.x, 100, accuracy: 1e-9); XCTAssertLessThan(v.y, 30)
        let d = DrawingGeometry.snappedEndpoint(from: o, to: CGPoint(x: 150, y: 140))
        XCTAssertEqual(d.x - 100, d.y - 100, accuracy: 1e-6)
    }

    func testSnapStaysInsideLimit() {
        let e = DrawingGeometry.snappedEndpoint(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 500, y: 12), within: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(e.x, 100, accuracy: 1e-9); XCTAssertEqual(e.y, 10, accuracy: 1e-9)
    }
}
