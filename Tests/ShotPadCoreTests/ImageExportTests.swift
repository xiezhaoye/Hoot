import AppKit
import XCTest
@testable import ShotPadCore

final class ImageExportTests: XCTestCase {
    func testContentBoundsTrimWhitePaperAndKeepTopLeftCoordinates() throws {
        let doc = EditorDocument(image: solid(120, 100, .white))
        var shape = Annotation(.rect(CGRect(x: 10, y: 20, width: 30, height: 15)), color: .black, lineWidth: 0)
        shape.fill = .solid; doc.add(shape)
        XCTAssertEqual(doc.contentBounds(), CGRect(x: 10, y: 20, width: 30, height: 15))
        doc.flattenAll()
        XCTAssertEqual(doc.contentBounds(), CGRect(x: 10, y: 20, width: 30, height: 15))
        XCTAssertNil(ImageRegion.contentBounds(in: solid(20, 10, .white)))
        XCTAssertEqual(EditorDocument(image: solid(20, 10, .white)).contentBounds(), CGRect(x: 0, y: 0, width: 20, height: 10))
    }

    func testCropAllowsWhitePaddingOutsideBoardAndIsUndoable() throws {
        let doc = EditorDocument(image: solid(20, 10, .black))
        doc.crop(to: CGRect(x: -5, y: -5, width: 30, height: 20))
        XCTAssertEqual(doc.size, CGSize(width: 30, height: 20))
        XCTAssertEqual(pixel(doc.state.base, 0, 0).0, 255)
        XCTAssertEqual(pixel(doc.state.base, 5, 5).0, 0)
        XCTAssertEqual(pixel(doc.state.base, 24, 14).0, 0)
        XCTAssertEqual(pixel(doc.state.base, 25, 15).0, 255)
        doc.undo(); XCTAssertEqual(doc.size, CGSize(width: 20, height: 10))
    }

    func testRegionExportPreservesOrientationAndDoesNotMutateDocument() throws {
        let doc = EditorDocument(image: solid(100, 80, .white))
        var a = Annotation(.rect(CGRect(x: 10, y: 20, width: 20, height: 10)), color: .black, lineWidth: 0)
        a.fill = .solid; doc.add(a)
        let region = try XCTUnwrap(doc.image(in: CGRect(x: 5, y: 15, width: 40, height: 30)))
        XCTAssertEqual(region.width, 40); XCTAssertEqual(region.height, 30)
        XCTAssertEqual(pixel(region, 5, 5).0, 0)
        XCTAssertEqual(pixel(region, 0, 0).0, 255)
        XCTAssertEqual(pixel(region, 5, 20).0, 255)
        XCTAssertEqual(doc.state.annotations.first?.id, a.id)
        XCTAssertEqual(doc.size, CGSize(width: 100, height: 80))
    }

    func testSolidBackgroundHasExactPaddingAndRoundedCorners() throws {
        var style = ImageExportStyle()
        style.background = .solid; style.color = .black; style.padding = 10
        style.shadow = false; style.cornerRadius = 5
        let image = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .white), style: style))
        XCTAssertEqual(image.width, 40); XCTAssertEqual(image.height, 30)
        XCTAssertEqual(pixel(image, 0, 0).0, 0)
        XCTAssertEqual(pixel(image, 10, 10).0, 0)
        XCTAssertEqual(pixel(image, 20, 15).0, 255)
    }

    func testGradientAndImageBackgroundCoverOutputWithoutStretchingContent() throws {
        var style = ImageExportStyle()
        style.background = .gradient; style.color = .black; style.gradientEnd = .white
        style.padding = 10; style.cornerRadius = 0; style.shadow = false
        let gradient = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .red), style: style))
        XCTAssertLessThan(pixel(gradient, 0, 0).0, pixel(gradient, 39, 29).0)
        style.background = .image
        XCTAssertNil(ImageExportRenderer.render(solid(20, 10, .red), style: style))
        let image = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .white), style: style, backgroundImage: solid(8, 30, .black)))
        XCTAssertEqual(pixel(image, 39, 29).0, 0)
        XCTAssertEqual(pixel(image, 15, 15).0, 255)
        let preview = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .white), style: style, backgroundImage: solid(8, 30, .black), scale: 0.5))
        XCTAssertEqual(preview.width, 20); XCTAssertEqual(preview.height, 15)
        let stripes = Renderer.makeContext(width: 90, height: 30)
        stripes.setFillColor(RGBA.black.cgColor); stripes.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        stripes.setFillColor(RGBA.red.cgColor); stripes.fill(CGRect(x: 30, y: 0, width: 30, height: 30))
        stripes.setFillColor(RGBA.white.cgColor); stripes.fill(CGRect(x: 60, y: 0, width: 30, height: 30))
        let centered = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .white), style: style, backgroundImage: stripes.makeImage()))
        XCTAssertGreaterThan(pixel(centered, 6, 1).0, 200)
        XCTAssertLessThan(pixel(centered, 6, 1).1, 80)
    }

    func testNoBackgroundProducesUnpaddedImageAndShadowChangesOnlyBackground() throws {
        var style = ImageExportStyle()
        style.background = .none
        let raw = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .red), style: style))
        XCTAssertEqual(raw.width, 20); XCTAssertEqual(raw.height, 10)
        style.background = .solid; style.color = .white; style.padding = 24; style.cornerRadius = 0
        style.shadow = false
        let flat = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .red), style: style))
        style.shadow = true
        let shadow = try XCTUnwrap(ImageExportRenderer.render(solid(20, 10, .red), style: style))
        XCTAssertLessThan(pixel(shadow, 30, 39).0, pixel(flat, 30, 39).0)
        XCTAssertEqual(pixel(shadow, 30, 29).1, pixel(flat, 30, 29).1)
    }

    func testFontAndExplicitTextWidthSurviveDraftRoundtrip() throws {
        let doc = EditorDocument(image: solid(400, 200, .white))
        var a = Annotation(.text("字体与换行", origin: CGPoint(x: 10, y: 10), fontSize: 24))
        a.fontName = "Menlo-Regular"; a.textFixedWidth = 80; a.boxWidth = 80; a.textAreaWidth = 80
        doc.add(a)
        let restored = try EditorDocument.restore(from: doc.archive())
        XCTAssertEqual(restored.state.annotations[0].fontName, a.fontName)
        XCTAssertEqual(restored.state.annotations[0].textFixedWidth, 80)
        XCTAssertEqual(restored.state.annotations[0].bounds, a.bounds)
        XCTAssertEqual(Renderer.textFont(name: "font-that-does-not-exist", size: 24), Renderer.textFont(name: nil, size: 24))
    }
}
