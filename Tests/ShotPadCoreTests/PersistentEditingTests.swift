import XCTest
import AppKit
@testable import ShotPadCore

final class PersistentEditingTests: XCTestCase {
    func testMultiplePastesStayIndependentAndReselectable() throws {
        let doc = EditorDocument(image: solid(200, 100, .white))
        doc.paste(solid(10, 10, .red), centeredAt: CGPoint(x: 30, y: 30))
        let first = try XCTUnwrap(doc.patch).id
        doc.paste(solid(10, 10, .black), centeredAt: CGPoint(x: 80, y: 30))
        XCTAssertEqual(doc.patches.count, 2)
        doc.selectedPatchID = first
        doc.setPatchRect(CGRect(x: 20, y: 20, width: 30, height: 30))
        XCTAssertEqual(doc.patches[0].rect.width, 30)
        XCTAssertEqual(doc.patches[1].rect.width, 10)
        XCTAssertEqual(doc.patch(at: CGPoint(x: 25, y: 25), slop: 0)?.id, first)
        XCTAssertEqual(pixel(doc.state.base, 25, 25).1, 255)
        XCTAssertEqual(pixel(doc.copyRegion(CGRect(x: 20, y: 20, width: 10, height: 10))!, 3, 3).1, 51)
    }
    func testFlattenAllOneUndoRestoresEveryObjectAndRedo() throws {
        let doc = EditorDocument(image: solid(100, 100, .white))
        doc.add(Annotation(.rect(CGRect(x: 5, y: 5, width: 10, height: 10))))
        doc.add(Annotation(.ellipse(CGRect(x: 30, y: 5, width: 10, height: 10))))
        doc.add(Annotation(.text("A", origin: CGPoint(x: 4, y: 40), fontSize: 20)))
        doc.paste(solid(5, 5, .black), centeredAt: CGPoint(x: 80, y: 80))
        let ids = doc.state.annotations.map(\.id), block = doc.patches[0].id
        doc.flattenAll()
        XCTAssertFalse(doc.hasEditableObjects)
        doc.undo()
        XCTAssertEqual(doc.state.annotations.map(\.id), ids)
        XCTAssertEqual(doc.patches[0].id, block)
        doc.redo(); XCTAssertFalse(doc.hasEditableObjects)
    }
    func testFlattenIncludesOutlyingPatchesAndUndoKeepsCoordinates() {
        let doc = EditorDocument(image: solid(20, 20, .white))
        doc.beginPatch(image: solid(10, 10, .black), rect: CGRect(x: -10, y: -5, width: 10, height: 10))
        let original = doc.patches[0].rect
        let exported = doc.flattened()
        XCTAssertEqual(exported.width, 30); XCTAssertEqual(exported.height, 25)
        XCTAssertEqual(doc.size.width, 20) // exports never implicitly flatten
        doc.flattenAll(); XCTAssertEqual(doc.size.width, 30)
        doc.undo(); XCTAssertEqual(doc.patches[0].rect, original)
    }
    func testDraftRoundtripPreservesObjectsStylesUndoAndRedo() throws {
        let doc = EditorDocument(image: solid(100, 100, .white))
        var a = Annotation(.text("A\n中文", origin: CGPoint(x: 10, y: 20), fontSize: 24))
        a.textAreaWidth = 320; a.opacity = 0.4; doc.add(a)
        doc.paste(solid(10, 10, .red), centeredAt: CGPoint(x: 50, y: 50))
        doc.flattenAll(); doc.undo()
        let restored = try EditorDocument.restore(from: doc.archive())
        XCTAssertEqual(restored.state.annotations[0].id, a.id)
        XCTAssertEqual(restored.state.annotations[0].opacity, 0.4)
        XCTAssertEqual(restored.state.annotations[0].textAreaWidth, 320)
        XCTAssertEqual(restored.patches[0].id, doc.patches[0].id)
        XCTAssertTrue(restored.canRedo)
        restored.redo(); XCTAssertFalse(restored.hasEditableObjects)
        restored.undo(); XCTAssertEqual(restored.patches.count, 1)
    }
    func testCorruptDraftFailsWithoutChangingDocument() {
        XCTAssertThrowsError(try EditorDocument.restore(from: Data("invalid".utf8)))
    }
    func testShortTextHasWideTransparentHitArea() {
        let a = Annotation(.text("A", origin: CGPoint(x: 10, y: 10), fontSize: 28))
        XCTAssertGreaterThanOrEqual(a.bounds!.width, 240)
        XCTAssertTrue(a.hit(CGPoint(x: 200, y: 20), slop: 0))
        XCTAssertNil(a.boxWidth)
    }
    func testTextWidthGrowsAndOnlyExplicitNewlinesGrowHeight() {
        let short = Renderer.textSize("A", fontSize: 24)
        let long = Renderer.textSize(String(repeating: "Long text ", count: 20), fontSize: 24)
        XCTAssertGreaterThan(long.width, 1000); XCTAssertEqual(short.height, long.height)
        let two = Renderer.textSize("A\n", fontSize: 24)
        XCTAssertEqual(two.height, short.height * 2)
        XCTAssertEqual(Renderer.textSize("A", fontSize: 24).height, short.height)
    }
    func testPenCanBeReselectedMovedAndRestyled() {
        let doc = EditorDocument(image: solid(100, 100, .white))
        var pen = Annotation(.pen([CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 10)]))
        doc.add(pen)
        XCTAssertEqual(doc.annotation(at: CGPoint(x: 30, y: 10), slop: 2, matching: { _ in true })?.id, pen.id)
        pen.color = .black; doc.replaceAnnotation(pen, record: true)
        pen.opacity = 0.5; doc.replaceAnnotation(pen, record: true)
        XCTAssertEqual(doc.annotation(pen.id)?.color, .black); XCTAssertEqual(doc.annotation(pen.id)?.opacity, 0.5)
        doc.undo(); XCTAssertEqual(doc.annotation(pen.id)?.opacity, 1)
    }
    func testDeletingPatchIsUndoable() {
        let doc = EditorDocument(image: solid(100, 100, .white))
        doc.paste(solid(10, 10, .red), centeredAt: CGPoint(x: 50, y: 50)); let id = doc.patch!.id
        doc.deletePatch(); XCTAssertTrue(doc.patches.isEmpty)
        doc.undo(); XCTAssertEqual(doc.patches.first?.id, id)
    }
}

final class ObjectCompositionTests: XCTestCase {
    func testNewAnnotationsRenderAbovePastedPixelsAndLaterPastesAboveAnnotations() {
        let doc = EditorDocument(image: solid(100, 100, .white))
        doc.beginPatch(image: solid(60, 60, .black), rect: CGRect(x: 10, y: 10, width: 60, height: 60))
        var rect = Annotation(.rect(CGRect(x: 20, y: 20, width: 30, height: 30)), color: RGBA(1, 0, 0))
        rect.fill = .solid; doc.add(rect)
        XCTAssertEqual(pixel(doc.flattened(), 30, 30).0, 255)
        XCTAssertFalse(doc.patchIsAboveAnnotations(doc.patches[0], at: CGPoint(x: 30, y: 30), slop: 0))
        doc.beginPatch(image: solid(10, 10, .white), rect: CGRect(x: 25, y: 25, width: 10, height: 10))
        XCTAssertEqual(pixel(doc.flattened(), 30, 30).1, 255)
        XCTAssertNil(doc.annotation(at: CGPoint(x: 30, y: 30), slop: 0, matching: { _ in true }))
        doc.undo(); XCTAssertEqual(pixel(doc.flattened(), 30, 30).1, 0)
    }
    func testResizedPatchCopyKeepsDisplayedDimensions() {
        let block = Patch(image: solid(10, 10, .red), rect: CGRect(x: 50, y: 50, width: 70, height: 40))
        XCTAssertEqual(block.rasterized().width, 70); XCTAssertEqual(block.rasterized().height, 40)
    }
    func testTextBeingEditedIsIncludedInExportAndArchive() throws {
        let doc = EditorDocument(image: solid(200, 100, .white))
        let text = Annotation(.text("HELLO", origin: CGPoint(x: 10, y: 10), fontSize: 40), color: .black)
        doc.add(text); doc.hiddenAnnotationID = text.id
        // Native text overlay hides the document's duplicate, never the exported content.
        let hidden = doc.composite(), exported = doc.flattened()
        var different = false
        for y in 10..<60 { for x in 10..<150 { if pixel(hidden, x, y).0 != pixel(exported, x, y).0 { different = true; break } } }
        XCTAssertTrue(different)
        let restored = try EditorDocument.restore(from: doc.archive())
        XCTAssertEqual(restored.state.annotations[0].id, text.id)
        XCTAssertNil(restored.hiddenAnnotationID)
    }
}

final class SelectionMutationTests: XCTestCase {
    func testErasingSelectionKeepsOtherObjectsEditable() {
        let doc = EditorDocument(image: solid(100, 100, .black))
        doc.add(Annotation(.text("A", origin: CGPoint(x: 50, y: 50), fontSize: 20)))
        doc.paste(solid(10, 10, .red), centeredAt: CGPoint(x: 70, y: 70))
        let id = doc.patch!.id
        doc.erase(CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertNotNil(doc.annotation(doc.state.annotations[0].id))
        XCTAssertTrue(doc.patches.contains { $0.id == id })
        XCTAssertNil(doc.patch(at: CGPoint(x: 10, y: 10), slop: 0)) // erase masks are not selectable blocks
        XCTAssertEqual(pixel(doc.flattened(), 10, 10).0, 255)
        doc.undo(); XCTAssertEqual(pixel(doc.flattened(), 10, 10).0, 0)
    }
    func testCropClipsPatchAndPreservesAnnotationIdentity() {
        let doc = EditorDocument(image: solid(100, 100, .white))
        let a = Annotation(.text("A", origin: CGPoint(x: 40, y: 40), fontSize: 20)); doc.add(a)
        doc.beginPatch(image: solid(40, 40, .black), rect: CGRect(x: 10, y: 10, width: 40, height: 40))
        let id = doc.patch!.id
        doc.crop(to: CGRect(x: 20, y: 20, width: 50, height: 50))
        XCTAssertEqual(doc.state.annotations.first?.id, a.id)
        XCTAssertEqual(doc.patches.first?.id, id)
        XCTAssertEqual(doc.patches.first?.rect, CGRect(x: 0, y: 0, width: 30, height: 30))
        XCTAssertEqual(doc.flattened().width, 50)
        doc.undo(); XCTAssertEqual(doc.patches.first?.rect, CGRect(x: 10, y: 10, width: 40, height: 40))
    }
}

final class MultilineExportTests: XCTestCase {
    func testExplicitNewlineSurvivesRasterExport() {
        let doc = EditorDocument(image: solid(160, 120, .white))
        doc.add(Annotation(.text("A\nB", origin: CGPoint(x: 10, y: 10), fontSize: 28), color: .black))
        let output = doc.flattened()
        func hasInk(_ rows: Range<Int>) -> Bool {
            for y in rows { for x in 10..<70 { if pixel(output, x, y).0 < 100 { return true } } }
            return false
        }
        XCTAssertTrue(hasInk(10..<40))
        XCTAssertTrue(hasInk(45..<75))
    }
}
