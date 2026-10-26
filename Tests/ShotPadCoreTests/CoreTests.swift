import AppKit
import XCTest
@testable import ShotPadCore

func solid(_ w: Int, _ h: Int, _ c: RGBA) -> CGImage {
    let ctx = Renderer.makeContext(width: w, height: h)
    ctx.setFillColor(c.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// Colour of pixel (x, y) counted from the top-left.
func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let ctx = Renderer.makeContext(width: 1, height: 1)
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

final class PatchTests: XCTestCase {
    func testResizeKeepsOppositeEdgeAndFlips() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(Patch.resized(r, handle: .right, to: CGPoint(x: 50, y: 99)), CGRect(x: 10, y: 10, width: 40, height: 20))
        XCTAssertEqual(Patch.resized(r, handle: .topLeft, to: CGPoint(x: 0, y: 5)), CGRect(x: 0, y: 5, width: 30, height: 25))
        // dragging past the opposite edge flips instead of collapsing
        XCTAssertEqual(Patch.resized(r, handle: .left, to: CGPoint(x: 40, y: 0)), CGRect(x: 30, y: 10, width: 10, height: 20))
        XCTAssertGreaterThanOrEqual(Patch.resized(r, handle: .right, to: CGPoint(x: 10, y: 0)).width, 1)
    }

    func testHitHandle() {
        let p = Patch(image: solid(2, 2, .red), rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertEqual(p.hitHandle(at: CGPoint(x: 31, y: 20), slop: 3), .right)
        XCTAssertNil(p.hitHandle(at: CGPoint(x: 20, y: 20), slop: 3))
    }
}

final class DocumentTests: XCTestCase {
    func testPasteStretchCoversAreaAndUndo() {
        // white canvas with a blue 10x10 block at the top-left
        let ctx = Renderer.makeContext(width: 100, height: 60)
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        ctx.setFillColor(RGBA(0, 0, 1).cgColor); ctx.fill(CGRect(x: 0, y: 50, width: 10, height: 10)) // memory top-left = y 50 in CG space
        let doc = EditorDocument(image: ctx.makeImage()!)
        XCTAssertEqual(pixel(doc.state.base, 5, 5).2, 255)
        XCTAssertEqual(pixel(doc.state.base, 5, 5).0, 0)

        let block = doc.copyRegion(CGRect(x: 0, y: 0, width: 10, height: 10))!
        doc.paste(block, centeredAt: CGPoint(x: 60, y: 30))
        XCTAssertEqual(doc.patch?.rect, CGRect(x: 55, y: 25, width: 10, height: 10))
        // stretch the patch to the right edge and bottom
        doc.setPatchRect(Patch.resized(doc.patch!.rect, handle: .bottomRight, to: CGPoint(x: 100, y: 60)))
        XCTAssertEqual(pixel(doc.flattened(), 99, 59).0, 0)            // covered while floating
        XCTAssertEqual(pixel(doc.state.base, 99, 59).0, 255)           // base untouched until commit
        doc.commitPatch()
        XCTAssertNil(doc.patch)
        XCTAssertEqual(pixel(doc.state.base, 99, 59).0, 0)
        XCTAssertEqual(pixel(doc.state.base, 54, 30).0, 255)           // outside the stretched block
        XCTAssertEqual(pixel(doc.state.base, 5, 5).2, 255)             // original block intact (copy, no hole)
        doc.undo()
        XCTAssertEqual(pixel(doc.state.base, 99, 59).0, 255)
        doc.redo()
        XCTAssertEqual(pixel(doc.state.base, 99, 59).0, 0)
    }

    func testStretchedContentIsNearestNeighbour() {
        // 2x1 patch: left red, right green -> stretched to 8x1 gives crisp halves
        let ctx = Renderer.makeContext(width: 2, height: 1)
        ctx.setFillColor(RGBA(1, 0, 0).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(RGBA(0, 1, 0).cgColor); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let doc = EditorDocument(image: solid(10, 4, .white))
        doc.beginPatch(image: ctx.makeImage()!, rect: CGRect(x: 0, y: 0, width: 8, height: 4))
        let out = doc.flattened()
        for x in 0..<4 { XCTAssertEqual(pixel(out, x, 1).0, 255); XCTAssertEqual(pixel(out, x, 1).1, 0) }
        for x in 4..<8 { XCTAssertEqual(pixel(out, x, 1).0, 0); XCTAssertEqual(pixel(out, x, 1).1, 255) }
    }

    func testPasteLandsAtCursorEvenOutsideCanvas() {
        let doc = EditorDocument(image: solid(50, 50, .white))
        doc.paste(solid(20, 20, .red), centeredAt: CGPoint(x: 49, y: 1))
        XCTAssertEqual(doc.patch?.rect, CGRect(x: 39, y: -9, width: 20, height: 20))
    }

    func testCropKeepsAnnotationsEditable() {
        let doc = EditorDocument(image: solid(40, 40, .white))
        doc.add(Annotation(.rect(CGRect(x: 10, y: 10, width: 20, height: 20)), color: .black, lineWidth: 4))
        XCTAssertEqual(doc.nextNumber(), 1)
        doc.crop(to: CGRect(x: 5, y: 5, width: 30, height: 30))
        XCTAssertEqual(doc.state.base.width, 30)
        XCTAssertEqual(doc.state.annotations.count, 1)
        XCTAssertEqual(pixel(doc.flattened(), 5, 15).0, 0)   // the rect's left edge survived the crop
        doc.undo()
        XCTAssertEqual(doc.state.base.width, 40)
    }

    func testMosaicHidesDetail() {
        let ctx = Renderer.makeContext(width: 20, height: 20)
        for y in 0..<20 { for x in 0..<20 {
            ctx.setFillColor((x + y) % 2 == 0 ? RGBA.black.cgColor : RGBA.white.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let doc = EditorDocument(image: ctx.makeImage()!)
        doc.add(Annotation(.mosaic(CGRect(x: 0, y: 0, width: 20, height: 20), block: 10)))
        let out = doc.rendered()
        XCTAssertEqual(pixel(out, 0, 0).0, pixel(out, 1, 0).0)  // neighbours now share a block colour
    }
}

final class HistoryTests: XCTestCase {
    func testAddUpdatePruneAndReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, limit: 2)
        let a = store.add(solid(10, 10, .red))!
        _ = store.add(solid(20, 20, .white))
        _ = store.add(solid(30, 30, .black))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertNil(store.image(for: a.id))                 // pruned file is gone
        let newest = store.entries[0]
        XCTAssertEqual(newest.width, 30)
        store.update(newest.id, with: solid(40, 40, .red))
        XCTAssertEqual(store.image(for: newest.id)?.width, 40)
        XCTAssertNotNil(store.thumbnail(for: newest.id, maxPixel: 16))
        let reloaded = HistoryStore(directory: dir, limit: 2)
        XCTAssertEqual(reloaded.entries.map(\.id), store.entries.map(\.id))
    }
}

final class OCRTests: XCTestCase {
    func testRecognizesRenderedEnglishAndChinese() throws {
        let ctx = Renderer.makeContext(width: 600, height: 200)
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        ctx.translateBy(x: 0, y: 200); ctx.scaleBy(x: 1, y: -1)
        Renderer.drawText(ctx, "Hello World", at: CGPoint(x: 20, y: 20), font: .systemFont(ofSize: 48), color: .black)
        Renderer.drawText(ctx, "你好世界", at: CGPoint(x: 20, y: 110), font: .systemFont(ofSize: 48), color: .black)
        let lines = try TextRecognizer.recognize(ctx.makeImage()!)
        let text = TextRecognizer.fullText(lines)
        XCTAssertTrue(text.contains("Hello World"), text)
        XCTAssertTrue(text.contains("你好"), text)
        XCTAssertLessThan(lines[0].rect.minY, lines[1].rect.minY)   // top-left origin, reading order
        XCTAssertTrue(TextRecognizer.isMostlyChinese("你好世界 ok"))
        XCTAssertFalse(TextRecognizer.isMostlyChinese("Hello 世"))
    }
}

final class LiftTests: XCTestCase {
    func testLiftLeavesWhiteAndMovesPixels() {
        let doc = EditorDocument(image: solid(40, 40, RGBA(0, 0, 1)))
        XCTAssertTrue(doc.liftSelection(CGRect(x: 10, y: 10, width: 10, height: 10)))
        doc.setPatchRect(CGRect(x: 25, y: 25, width: 10, height: 10))
        let out = doc.flattened()
        XCTAssertEqual(pixel(out, 12, 12).0, 255)         // vacated -> white
        XCTAssertEqual(pixel(out, 30, 30).2, 255)         // moved blue block
        XCTAssertEqual(pixel(out, 30, 30).0, 0)
        doc.cancelPatch()
        XCTAssertNil(doc.patch)
        XCTAssertEqual(doc.patches.count, 1)  // Escape only deselects
        doc.undo(); doc.undo()
        XCTAssertEqual(pixel(doc.flattened(), 12, 12).0, 0)   // undo restores
    }

    func testOversizedPasteFitsCanvas() {
        let doc = EditorDocument(image: solid(100, 50, .white))
        doc.paste(solid(400, 200, .red), centeredAt: CGPoint(x: 50, y: 25))
        XCTAssertEqual(doc.patch?.rect, CGRect(x: 0, y: 0, width: 100, height: 50))
    }
}

final class EditingTests: XCTestCase {
    func testCommitOutsideGrowsCanvasWhiteAndShiftsAnnotations() {
        let doc = EditorDocument(image: solid(50, 50, RGBA(0, 0, 1)))
        let rect = Annotation(.rect(CGRect(x: 10, y: 10, width: 20, height: 20)), color: .black, lineWidth: 2)
        doc.add(rect)
        doc.paste(solid(20, 20, .red), centeredAt: CGPoint(x: 5, y: 5))      // sticks out left/top by 5
        doc.commitPatch()
        XCTAssertEqual(doc.size, CGSize(width: 55, height: 55))
        let out = doc.rendered()
        XCTAssertEqual(pixel(out, 1, 1).0, 242)                  // red patch
        XCTAssertTrue(pixel(out, 53, 1) == (255, 255, 255))       // grown white area (top-right)
        XCTAssertEqual(pixel(out, 40, 40).2, 255)                // old blue content moved by (5,5)
        doc.undo()
        XCTAssertEqual(doc.size, CGSize(width: 50, height: 50))
    }

    func testEraseAndDeletePatch() {
        let doc = EditorDocument(image: solid(30, 30, RGBA(0, 0, 1)))
        doc.erase(CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertTrue(pixel(doc.rendered(), 8, 8) == (255, 255, 255))
        doc.liftSelection(CGRect(x: 20, y: 20, width: 5, height: 5))
        doc.deletePatch()
        XCTAssertNil(doc.patch)
        XCTAssertTrue(pixel(doc.rendered(), 22, 22) == (255, 255, 255))
    }

    func testHitAndDragAnnotations() {
        let r = Annotation(.rect(CGRect(x: 10, y: 10, width: 40, height: 30)), color: .black, lineWidth: 2)
        XCTAssertTrue(r.hit(CGPoint(x: 10, y: 25), slop: 3))
        XCTAssertFalse(r.hit(CGPoint(x: 30, y: 25), slop: 3))        // inside an outline is empty
        let moved = r.dragged(.box(.bottomRight), to: CGPoint(x: 70, y: 60))
        if case .rect(let nr) = moved.kind { XCTAssertEqual(nr.maxX, 69); XCTAssertEqual(nr.minX, 10) } else { XCTFail() }
        XCTAssertEqual(moved.id, r.id)
        let line = Annotation(.line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)), lineWidth: 2)
        XCTAssertTrue(line.hit(CGPoint(x: 50, y: 2), slop: 3))
        XCTAssertFalse(line.hit(CGPoint(x: 50, y: 20), slop: 3))
    }

    func testTextCornerScalesFontAndSideKeepsUnwrapped() {
        let t = Annotation(.text("Hello world", origin: CGPoint(x: 10, y: 10), fontSize: 20))
        let b = t.bounds!
        let grown = t.dragged(.box(.bottomRight), to: CGPoint(x: b.minX + b.width * 2, y: b.maxY * 2))
        if case .text(_, _, let size) = grown.kind { XCTAssertEqual(size, 40, accuracy: 0.5) } else { XCTFail() }
        let wrapped = t.dragged(.box(.right), to: CGPoint(x: b.minX + 40, y: 0))
        XCTAssertNil(wrapped.boxWidth)
        XCTAssertGreaterThanOrEqual(wrapped.textAreaWidth, 240)
        if case .text(_, _, let size) = wrapped.kind { XCTAssertEqual(size, 20) } else { XCTFail() }
    }
}

final class LLMTests: XCTestCase {
    func testEndpointVariants() {
        XCTAssertEqual(LLMTranslator.endpoint("https://api.x.com/v1")?.absoluteString, "https://api.x.com/v1/chat/completions")
        XCTAssertEqual(LLMTranslator.endpoint("https://api.x.com/v1/")?.absoluteString, "https://api.x.com/v1/chat/completions")
        XCTAssertEqual(LLMTranslator.endpoint("https://a/v1/chat/completions")?.absoluteString, "https://a/v1/chat/completions")
        XCTAssertNil(LLMTranslator.endpoint("  "))
        XCTAssertNil(LLMTranslator.endpoint("ftp://a"))
    }

    func testRequestBody() throws {
        let r = LLMTranslator.makeRequest(lines: ["Hello", "World"], toChinese: true, config: LLMConfig(baseURL: "https://a/v1", apiKey: "k", model: "m"))!
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "m")
        let msgs = body["messages"] as! [[String: String]]
        XCTAssertEqual(msgs[1]["content"], "[\"Hello\",\"World\"]")
    }

    func testParseHandlesFencesAndMismatch() throws {
        func reply(_ content: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        XCTAssertEqual(try LLMTranslator.parse(reply("```json\n[\"你好\",\"世界\"]\n```"), expected: 2), ["你好", "世界"])
        XCTAssertThrowsError(try LLMTranslator.parse(reply("[\"a\"]"), expected: 2))
        XCTAssertThrowsError(try LLMTranslator.parse(reply("nope"), expected: 1))
    }
}

final class HistoryGroupTests: XCTestCase {
    func testGroupPersistsAndOldIndexDefaultsToNormal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: dir, limit: 5)
        let e = store.add(solid(4, 4, .red), group: .ocr)!
        store.setGroup(e.id, .translate)
        XCTAssertEqual(HistoryStore(directory: dir, limit: 5).entries.first?.group, .translate)
        XCTAssertTrue(store.thumbnail(for: e.id) === store.thumbnail(for: e.id))   // cached
        // an index written by an older version points at "<id>.png"
        try FileManager.default.copyItem(at: dir.appendingPathComponent(e.fileName!), to: dir.appendingPathComponent("\(e.id.uuidString).png"))
        let old = #"[{"id":"\#(e.id.uuidString)","date":0,"width":4,"height":4}]"#
        try old.write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HistoryStore(directory: dir, limit: 5).entries.first?.group, .normal)
    }
}


final class BrowseStoreTests: XCTestCase {
    func testGroupsFoldersAndListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browse-\(UUID().uuidString)")
        let pics = root.appendingPathComponent("pics")
        try FileManager.default.createDirectory(at: pics.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for n in ["b10.png", "b2.PNG", "a.jpg", "note.txt", ".hidden.png"] { FileManager.default.createFile(atPath: pics.appendingPathComponent(n).path, contents: Data()) }
        FileManager.default.createFile(atPath: pics.appendingPathComponent("sub/deep.png").path, contents: Data())

        let file = root.appendingPathComponent("browse.json")
        let store = BrowseStore(file: file)
        let g = store.addGroup("旅行")
        XCTAssertNotNil(store.addFolder(pics, to: g.id))
        XCTAssertNil(store.addFolder(pics, to: g.id), "duplicate folder in a group is rejected")
        store.renameGroup(g.id, to: "工作")

        let reloaded = BrowseStore(file: file)
        XCTAssertEqual(reloaded.groups.first?.name, "工作")
        XCTAssertEqual(reloaded.groups.first?.folders.count, 1)
        XCTAssertTrue(reloaded.groups[0].folders[0].exists)

        let names = BrowseStore.images(in: pics).map(\.lastPathComponent)
        XCTAssertEqual(names, ["a.jpg", "b2.PNG", "b10.png"])

        reloaded.removeFolder(reloaded.groups[0].folders[0].id, from: g.id)
        XCTAssertTrue(reloaded.groups[0].folders.isEmpty)
        reloaded.removeGroup(g.id)
        XCTAssertTrue(reloaded.groups.isEmpty)
    }
}


final class BoardTests: XCTestCase {
    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return px
    }

    func testShotSitsTopLeftOnFixedBoard() {
        let b = Board.make(placing: solid(100, 50), size: CGSize(width: 400, height: 300))
        XCTAssertEqual(b.width, 400); XCTAssertEqual(b.height, 300)
        XCTAssertGreaterThan(pixel(b, 10, 10)[0], 200); XCTAssertLessThan(pixel(b, 10, 10)[1], 80)   // shot, top-left
        XCTAssertEqual(pixel(b, 200, 200)[1], 255)                                          // white elsewhere
        XCTAssertEqual(pixel(b, 10, 80)[1], 255)                                            // below the shot
    }

    func testBoardGrowsForLargeShot() {
        let b = Board.make(placing: solid(800, 600), size: CGSize(width: 400, height: 300))
        XCTAssertEqual(b.width, 800); XCTAssertEqual(b.height, 600)
    }
}

final class FormatTests: XCTestCase {
    func testStoreWritesReadableFileInChosenFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString)")
        let store = HistoryStore(directory: dir)
        let img = Board.blank(size: CGSize(width: 40, height: 30))!
        for fmt in [ImageFormat.png, .jpeg, .tiff, .bmp, .gif] {
            let e = try XCTUnwrap(store.add(img, format: fmt, namePrefix: "画板"), "\(fmt)")
            XCTAssertTrue(e.fileName?.hasPrefix("画板 ") == true && e.fileName?.hasSuffix("." + fmt.fileExtension) == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(e.fileName!).path))
            XCTAssertEqual(store.image(for: e.id)?.width, 40)
        }
        // same second, same prefix and format: the name is numbered, not overwritten
        let d = Date()
        let a = store.add(img, date: d), b = store.add(img, date: d)
        XCTAssertNotEqual(a?.fileName, b?.fileName)
        // survives a reload, and removing an entry removes its file
        let again = HistoryStore(directory: dir)
        XCTAssertEqual(again.entries.count, store.entries.count)
        if let e = again.entries.first {
            again.remove(e.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(e.fileName!).path))
        }
    }
}
