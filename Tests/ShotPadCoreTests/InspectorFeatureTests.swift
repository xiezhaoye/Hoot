import AppKit
import XCTest
@testable import ShotPadCore

final class InspectorFeatureTests: XCTestCase {
    func testFilledRoundedShapeRendersAndUsesMatchingHitArea() {
        let doc = EditorDocument(image: solid(80, 80, .white))
        var shape = Annotation(.rect(CGRect(x: 10, y: 10, width: 60, height: 60)), color: RGBA(0, 0, 1), lineWidth: 2)
        shape.fill = .solid
        shape.cornerRadius = 18
        doc.add(shape)
        XCTAssertEqual(pixel(doc.rendered(), 40, 40).0, 0)
        XCTAssertEqual(pixel(doc.rendered(), 12, 12).0, 255)
        XCTAssertTrue(shape.hit(CGPoint(x: 40, y: 40), slop: 0))
        XCTAssertFalse(shape.hit(CGPoint(x: 11, y: 11), slop: 0))
    }

    func testOpacityAndFillAreIncludedInUndoAndExport() {
        let doc = EditorDocument(image: solid(80, 80, .white))
        var shape = Annotation(.ellipse(CGRect(x: 10, y: 10, width: 60, height: 60)), color: RGBA(0, 0, 1))
        shape.fill = .translucent
        shape.opacity = 0.5
        doc.add(shape)
        let faint = pixel(doc.flattened(), 40, 40).0
        XCTAssertTrue((230...240).contains(faint))
        shape.fill = .solid; shape.opacity = 1
        doc.replaceAnnotation(shape, record: true)
        XCTAssertEqual(pixel(doc.flattened(), 40, 40).0, 0)
        doc.undo()
        XCTAssertEqual(pixel(doc.flattened(), 40, 40).0, faint)
        doc.redo()
        XCTAssertEqual(pixel(doc.flattened(), 40, 40).0, 0)
    }

    func testReorderingChangesOverlapAndCanBeUndone() {
        let doc = EditorDocument(image: solid(80, 80, .white))
        var red = Annotation(.rect(CGRect(x: 10, y: 10, width: 50, height: 50)), color: RGBA(1, 0, 0))
        red.fill = .solid
        var blue = Annotation(.rect(CGRect(x: 20, y: 20, width: 50, height: 50)), color: RGBA(0, 0, 1))
        blue.fill = .solid
        doc.add(red); doc.add(blue)
        XCTAssertEqual(pixel(doc.rendered(), 30, 30).2, 255)
        doc.reorderAnnotation(red.id, toFront: true)
        XCTAssertEqual(doc.state.annotations.last?.id, red.id)
        XCTAssertEqual(pixel(doc.rendered(), 30, 30).2, 0)
        doc.undo()
        XCTAssertEqual(doc.state.annotations.last?.id, blue.id)
        doc.redo()
        XCTAssertEqual(doc.state.annotations.last?.id, red.id)
        doc.reorderAnnotation(red.id, toFront: false)
        XCTAssertEqual(doc.state.annotations.first?.id, red.id)
    }

    func testRectangleFrameEditKeepsIdentityStyleAndStrokeBounds() {
        var original = Annotation(.rect(CGRect(x: 10, y: 20, width: 30, height: 40)), lineWidth: 4)
        original.fill = .translucent; original.cornerRadius = 6; original.opacity = 0.7; original.shadow = true
        let frame = CGRect(x: 100, y: 80, width: 120, height: 90)
        let resized = original.settingFrame(frame)
        XCTAssertEqual(resized.id, original.id)
        XCTAssertEqual(resized.bounds, frame)
        XCTAssertEqual(resized.fill, original.fill)
        XCTAssertEqual(resized.cornerRadius, original.cornerRadius)
        XCTAssertEqual(resized.opacity, original.opacity)
        XCTAssertTrue(resized.shadow)
    }

    func testReversedArrowFrameMaintainsDirection() {
        let arrow = Annotation(.arrow(CGPoint(x: 100, y: 80), CGPoint(x: 10, y: 20)), lineWidth: 4)
        let frame = CGRect(x: 30, y: 40, width: 200, height: 100)
        let resized = arrow.settingFrame(frame)
        XCTAssertEqual(resized.bounds, frame)
        if case .arrow(let start, let end) = resized.kind {
            XCTAssertGreaterThan(start.x, end.x); XCTAssertGreaterThan(start.y, end.y)
        } else { XCTFail() }
    }

    func testTextFrameWidthSetsWrapWidthAndHeightScalesFont() {
        let text = Annotation(.text("Hello world", origin: CGPoint(x: 10, y: 20), fontSize: 20))
        let bounds = text.bounds!
        let wrapped = text.settingFrame(CGRect(x: 10, y: 20, width: 40, height: bounds.height))
        XCTAssertEqual(wrapped.boxWidth, 40)
        XCTAssertEqual(wrapped.textFixedWidth, 40)
        XCTAssertEqual(wrapped.textAreaWidth, 40)
        if case .text(_, _, let font) = wrapped.kind { XCTAssertEqual(font, 20) } else { XCTFail() }
        let scaled = text.settingFrame(CGRect(x: 10, y: 20, width: bounds.width * 2, height: bounds.height * 2))
        if case .text(_, _, let font) = scaled.kind { XCTAssertEqual(font, 40) } else { XCTFail() }
    }

    func testSquareConstraintHandlesEveryDragDirection() {
        let start = CGPoint(x: 10, y: 10)
        XCTAssertEqual(DrawingGeometry.squareEndpoint(from: start, to: CGPoint(x: 30, y: 15)), CGPoint(x: 30, y: 30))
        XCTAssertEqual(DrawingGeometry.squareEndpoint(from: start, to: CGPoint(x: -10, y: 15)), CGPoint(x: -10, y: 30))
        XCTAssertEqual(DrawingGeometry.squareEndpoint(from: start, to: CGPoint(x: 30, y: 5)), CGPoint(x: 30, y: -10))
        XCTAssertEqual(DrawingGeometry.squareEndpoint(from: start, to: CGPoint(x: -10, y: 5)), CGPoint(x: -10, y: -10))
    }

    func testPositionEditsPreserveHorizontalLinesAndUnwrappedText() {
        let line = Annotation(.line(CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 20)), lineWidth: 4)
        let moved = line.settingFrame(line.bounds!.offsetBy(dx: 15, dy: 30))
        if case .line(let start, let end) = moved.kind {
            XCTAssertEqual(start, CGPoint(x: 25, y: 50))
            XCTAssertEqual(end, CGPoint(x: 95, y: 50))
        } else { XCTFail() }
        let text = Annotation(.text("Hello world", origin: CGPoint(x: 10, y: 20), fontSize: 20))
        let movedText = text.settingFrame(text.bounds!.offsetBy(dx: 15, dy: 30))
        XCTAssertNil(movedText.boxWidth)
        XCTAssertEqual(movedText.bounds!.size, text.bounds!.size)
    }

    func testShadowIsVisibleBeyondTheShape() {
        let doc = EditorDocument(image: solid(80, 80, .white))
        var rect = Annotation(.rect(CGRect(x: 20, y: 20, width: 40, height: 40)), color: .black, lineWidth: 2)
        rect.shadow = true
        doc.add(rect)
        let image = doc.rendered()
        let samples = [CGPoint(x: 63, y: 40), CGPoint(x: 40, y: 63), CGPoint(x: 40, y: 16)]
        XCTAssertTrue(samples.contains { pixel(image, Int($0.x), Int($0.y)).0 < 250 })
    }
}
