import AppKit
import XCTest
import SwiftUI
import ShotPadCore
@testable import ShotPad

@MainActor
final class CanvasInteractionTests: XCTestCase {
    func testSelectedShapesMoveFromEmptyInteriorAcrossRepeatedDrags() async throws {
        for tool in [Tool.rect, .ellipse, .line, .arrow, .pen, .highlighter] {
            let editor = EditorHarness(tool: tool)
            defer { editor.close() }
            editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
            let original = try XCTUnwrap(editor.canvas.selectedAnnotation, "\(tool)")
            let point = CGPoint(x: 60, y: 100) // Empty space inside the selection, away from the stroke and handles.
            XCTAssertFalse(original.hit(point, slop: 0), "\(tool)")

            editor.click(point)
            XCTAssertEqual(editor.canvas.selectedAnnotation?.id, original.id, "\(tool)")
            XCTAssertEqual(editor.model.doc.annotation(original.id)?.bounds, original.bounds)

            editor.drag(from: point, to: CGPoint(x: 90, y: 120))
            let moved = try XCTUnwrap(editor.canvas.selectedAnnotation)
            XCTAssertEqual(moved.id, original.id)
            XCTAssertEqual(moved.bounds, original.bounds?.offsetBy(dx: 30, dy: 20))
            editor.drag(from: CGPoint(x: 90, y: 120), to: CGPoint(x: 110, y: 130))
            XCTAssertEqual(editor.canvas.selectedAnnotation?.bounds, original.bounds?.offsetBy(dx: 50, dy: 30))
            XCTAssertEqual(editor.model.doc.state.annotations.count, 1)

            editor.canvas.undo()
            XCTAssertEqual(editor.model.doc.annotation(original.id)?.bounds, moved.bounds)
        }
    }

    func testClickOutsideFixesShapeAndUndoRestoresIt() async throws {
        for tool in [Tool.rect, .ellipse, .line, .arrow, .pen, .highlighter] {
            let editor = EditorHarness(tool: tool)
            defer { editor.close() }
            editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
            let shape = try XCTUnwrap(editor.canvas.selectedAnnotation)
            // Hovering outside does not fix it.
            editor.moveMouse(to: CGPoint(x: 280, y: 250))
            XCTAssertEqual(editor.canvas.selectedAnnotation?.id, shape.id)
            editor.click(CGPoint(x: 280, y: 250))
            XCTAssertNotEqual(editor.canvas.selectedAnnotation?.id, shape.id)
            XCTAssertNil(editor.model.doc.annotation(shape.id))
            XCTAssertNil(editor.model.doc.annotation(at: CGPoint(x: 20, y: 20), slop: 10, matching: { _ in true }))

            // The pen tools create a new dot on the outside click; undo that before the fix.
            if tool == .pen || tool == .highlighter { editor.canvas.undo() }
            editor.canvas.undo()
            XCTAssertEqual(editor.model.doc.annotation(shape.id)?.bounds, shape.bounds)
            // A restored object can be picked up again, rather than immediately fixed on mouse-down.
            editor.click(tool == .ellipse ? CGPoint(x: 100, y: 20) : CGPoint(x: 20, y: 20))
            XCTAssertEqual(editor.canvas.selectedAnnotation?.id, shape.id, "\(tool)")
        }
    }

    func testChoosingAnotherToolFixesCurrentShape() async throws {
        let editor = EditorHarness(tool: .rect)
        defer { editor.close() }
        editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
        let shape = try XCTUnwrap(editor.canvas.selectedAnnotation)
        editor.model.chooseTool(.ellipse)
        XCTAssertFalse(editor.model.doc.hasEditableObjects)
        XCTAssertNil(editor.canvas.selectedAnnotation)
        editor.canvas.undo()
        XCTAssertNotNil(editor.model.doc.annotation(shape.id))
    }

    func testAllBoxHandlesShowResizeCursorAndResizeInsteadOfMoving() async throws {
        for tool in [Tool.rect, .ellipse] {
            try checkBoxHandles(tool: tool)
        }
    }

    private func checkBoxHandles(tool: Tool) throws {
        let editor = EditorHarness(tool: tool)
        defer { editor.close() }
        editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
        let shape = try XCTUnwrap(editor.canvas.selectedAnnotation)
        editor.moveMouse(to: CGPoint(x: 60, y: 100))
        XCTAssertEqual(NSCursor.current, NSCursor.openHand)
        for (handle, point) in shape.handles {
            editor.moveMouse(to: point)
            XCTAssertNotEqual(NSCursor.current, NSCursor.crosshair, "\(handle)")
            XCTAssertNotEqual(NSCursor.current, NSCursor.openHand, "\(handle)")
            editor.drag(from: point, to: CGPoint(x: point.x - 20, y: point.y - 20))
            let resized = try XCTUnwrap(editor.model.doc.annotation(shape.id))
            XCTAssertEqual(resized.bounds, shape.dragged(handle, to: CGPoint(x: point.x - 20, y: point.y - 20)).bounds)
            // Restore geometry without clearing the selection, to check the next handle.
            editor.model.doc.replaceAnnotation(shape, record: false)
        }
    }

    func testLineAndArrowEndpointsShowDragCursorAndMoveOnlyThatEndpoint() async throws {
        for tool in [Tool.line, .arrow] {
            let editor = EditorHarness(tool: tool)
            defer { editor.close() }
            editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
            let shape = try XCTUnwrap(editor.canvas.selectedAnnotation)
            for (handle, point) in shape.handles {
                editor.moveMouse(to: point)
                XCTAssertEqual(NSCursor.current, NSCursor.openHand)
                let end = CGPoint(x: point.x + 20, y: point.y + 10)
                editor.drag(from: point, to: end)
                XCTAssertEqual(editor.model.doc.annotation(shape.id)?.bounds, shape.dragged(handle, to: end).bounds)
                editor.model.doc.replaceAnnotation(shape, record: false)
            }
        }
    }

    func testAutoFixKeepsNumberToolCounting() async throws {
        let editor = EditorHarness(tool: .number)
        defer { editor.close() }
        editor.click(CGPoint(x: 50, y: 50))
        editor.click(CGPoint(x: 250, y: 200))
        guard case .number(let value, _, _) = try XCTUnwrap(editor.canvas.selectedAnnotation).kind else {
            return XCTFail("Expected a number annotation")
        }
        XCTAssertEqual(value, 2)
    }

    func testStyleChangesKeepSelectionAndKeyboardToolChangesFixIt() async throws {
        for key in ["\u{1b}", "a"] {
            let editor = EditorHarness(tool: .rect)
            defer { editor.close() }
            editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
            let shape = try XCTUnwrap(editor.canvas.selectedAnnotation)
            editor.model.lineWidth = 5
            XCTAssertEqual(editor.canvas.selectedAnnotation?.id, shape.id)
            XCTAssertEqual(editor.model.doc.annotation(shape.id)?.lineWidth, 5)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key == "a" ? .command : [], timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: key == "a" ? 0 : 53))
            if key == "a" { XCTAssertTrue(editor.canvas.performKeyEquivalent(with: event)) }
            else { editor.canvas.keyDown(with: event) }
            XCTAssertNil(editor.model.doc.annotation(shape.id))
            XCTAssertNil(editor.canvas.selectedAnnotation)
        }
    }

    func testDrawingAndResponderProbesDoNotCopyOrShowCopyNotice() async throws {
        let editor = EditorHarness(tool: .rect)
        defer { editor.close() }
        let count = NSPasteboard.general.changeCount
        for tool in [Tool.rect, .ellipse, .number, .text] {
            editor.model.chooseTool(tool)
            if editor.model.tool != tool { editor.model.chooseTool(tool) }
            if tool == .number || tool == .text { editor.click(CGPoint(x: 40, y: 40)) }
            else { editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140)) }
            editor.canvas.copyAction(nil)
            editor.canvas.copyAction(editor.canvas)
            XCTAssertEqual(NSPasteboard.general.changeCount, count, "\(tool)")
            XCTAssertFalse(editor.model.status.contains("复制"), "\(tool)")
        }
    }

    func testTextGrowsWhileTypingAndManualWidthEnablesWrapping() async throws {
        let editor = EditorHarness(tool: .text)
        defer { editor.close() }
        editor.model.fontSize = 48 // Formerly this made a new box look like a manually sized box.
        editor.click(CGPoint(x: 20, y: 20))
        let field = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
        field.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        let first = try XCTUnwrap(editor.canvas.selectedAnnotation?.bounds)
        field.insertText(" world 中文输入继续增长", replacementRange: NSRange(location: field.string.utf16.count, length: 0))
        let grown = try XCTUnwrap(editor.canvas.selectedAnnotation?.bounds)
        XCTAssertGreaterThan(grown.width, first.width)
        XCTAssertEqual(field.frame.width, grown.width * editor.canvas.zoom, accuracy: 0.01)
        XCTAssertNil(editor.canvas.selectedAnnotation?.textFixedWidth)
        XCTAssertNil(editor.canvas.selectedAnnotation?.boxWidth)
        let outer = grown.insetBy(dx: -4, dy: -4)
        editor.drag(from: Handle.right.point(in: outer), to: CGPoint(x: outer.minX + 140, y: outer.midY))
        XCTAssertNotNil(editor.canvas.selectedAnnotation?.boxWidth)
        XCTAssertGreaterThan(try XCTUnwrap(editor.canvas.selectedAnnotation?.bounds).height, grown.height)
        XCTAssertEqual(field.font?.pointSize, 48 * editor.canvas.zoom)
        XCTAssertEqual(field.frame.height, try XCTUnwrap(editor.canvas.selectedAnnotation?.bounds).height * editor.canvas.zoom, accuracy: 0.01)
    }

    func testLiveTextCornersResizeFontAndOwnHitArea() async throws {
        for handle in [Handle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let editor = EditorHarness(tool: .text)
            defer { editor.close() }
            editor.click(CGPoint(x: 60, y: 60))
            let field = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
            field.insertText("文字 Text", replacementRange: NSRange(location: 0, length: 0))
            let original = try XCTUnwrap(editor.canvas.selectedAnnotation)
            let outer = try XCTUnwrap(original.bounds).insetBy(dx: -4, dy: -4)
            let point = handle.point(in: outer)
            XCTAssertTrue(editor.hitView(at: point) === editor.canvas)
            editor.moveMouse(to: point)
            XCTAssertNotEqual(NSCursor.current, NSCursor.crosshair)
            let anchor = CGPoint(x: handle.movesLeft ? outer.maxX : outer.minX, y: handle.movesTop ? outer.maxY : outer.minY)
            let end = CGPoint(x: anchor.x + (point.x - anchor.x) * 1.5, y: anchor.y + (point.y - anchor.y) * 1.5)
            editor.drag(from: point, to: end)
            guard case .text(_, _, let size) = try XCTUnwrap(editor.canvas.selectedAnnotation).kind else { return XCTFail() }
            XCTAssertEqual(size, 42, accuracy: 0.01)
            XCTAssertEqual(editor.model.fontSize, size)
            XCTAssertEqual(field.font?.pointSize, size * editor.canvas.zoom)
            let newOuter = try XCTUnwrap(editor.canvas.selectedAnnotation?.bounds).insetBy(dx: -4, dy: -4)
            XCTAssertEqual(handle.movesLeft ? newOuter.maxX : newOuter.minX, anchor.x, accuracy: 0.01)
            XCTAssertEqual(handle.movesTop ? newOuter.maxY : newOuter.minY, anchor.y, accuracy: 0.01)
        }
    }

    func testChangingFontUpdatesLiveEditorAndStoredAnnotation() async throws {
        let editor = EditorHarness(tool: .text)
        defer { editor.close() }
        editor.click(CGPoint(x: 20, y: 20))
        let field = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
        field.insertText("WWWWiiii", replacementRange: NSRange(location: 0, length: 0))
        editor.model.fontName = "Menlo-Regular"
        XCTAssertEqual(field.font?.fontName, "Menlo-Regular")
        XCTAssertEqual(editor.canvas.selectedAnnotation?.fontName, "Menlo-Regular")
        XCTAssertNil(editor.canvas.selectedAnnotation?.boxWidth)
        editor.canvas.finishTextEditing()
        XCTAssertEqual(editor.model.doc.state.annotations.first?.fontName, "Menlo-Regular")
    }

    func testCropAutomaticallyFramesContentAndAllHandlesAdjustIt() async throws {
        let clipboard = ClipboardSnapshot()
        defer { clipboard.restore() }
        let editor = EditorHarness(tool: .rect)
        defer { editor.close() }
        editor.model.cropPadding = -1
        XCTAssertEqual(editor.model.cropPadding, 0)
        editor.model.cropPadding = 101
        XCTAssertEqual(editor.model.cropPadding, 100)
        editor.model.cropPadding = 0
        editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
        let expected = editor.model.doc.contentBounds()
        editor.model.inspectorVisible = false
        editor.model.chooseTool(.crop)
        XCTAssertTrue(editor.model.inspectorVisible)
        XCTAssertEqual(editor.canvas.activeSelectionRect, expected)
        for handle in Handle.allCases {
            let point = handle.point(in: expected)
            editor.moveMouse(to: point)
            XCTAssertNotEqual(NSCursor.current, NSCursor.crosshair)
            let end = CGPoint(x: point.x + (handle.movesLeft ? -5 : handle.movesRight ? 5 : 0),
                              y: point.y + (handle.movesTop ? -5 : handle.movesBottom ? 5 : 0))
            editor.drag(from: point, to: end)
            let rect = try XCTUnwrap(editor.canvas.activeSelectionRect)
            XCTAssertEqual(rect.minX, expected.minX - (handle.movesLeft ? 5 : 0))
            XCTAssertEqual(rect.maxX, expected.maxX + (handle.movesRight ? 5 : 0))
            XCTAssertEqual(rect.minY, expected.minY - (handle.movesTop ? 5 : 0))
            XCTAssertEqual(rect.maxY, expected.maxY + (handle.movesBottom ? 5 : 0))
            editor.canvas.beginCrop()
        }
        editor.model.cropPadding = 10
        XCTAssertEqual(editor.canvas.activeSelectionRect, expected.insetBy(dx: -10, dy: -10))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.canvas.keyDown(with: key)
        XCTAssertEqual(editor.model.doc.size, expected.insetBy(dx: -10, dy: -10).size)
        let copied = try XCTUnwrap(Clipboard.readImage())
        XCTAssertEqual(copied.width, Int(editor.model.doc.size.width))
        XCTAssertEqual(copied.height, Int(editor.model.doc.size.height))
        XCTAssertTrue(editor.model.status.contains("已裁剪并复制"))
        editor.model.chooseTool(.text)
        XCTAssertNil(editor.canvas.activeSelectionRect)
        editor.model.chooseTool(.crop)
        XCTAssertNotNil(editor.canvas.activeSelectionRect)
        editor.canvas.undo()
        XCTAssertEqual(editor.model.doc.size, CGSize(width: 400, height: 300))
    }

    func testBackgroundCopyAndSaveExportOnlySelectionWithoutChangingCanvas() async throws {
        let clipboard = ClipboardSnapshot()
        defer { clipboard.restore() }
        let editor = EditorHarness(tool: .select)
        defer { editor.close() }
        editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
        let region = editor.canvas.selectionRect
        editor.model.exportStyle.background = .solid; editor.model.exportStyle.color = .black
        editor.model.exportStyle.padding = 12; editor.model.exportStyle.cornerRadius = 0; editor.model.exportStyle.shadow = false
        editor.model.copyRegionImage()
        let copied = try XCTUnwrap(Clipboard.readImage())
        XCTAssertEqual(copied.width, 184); XCTAssertEqual(copied.height, 144)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(editor.model.saveRegionImage(to: url))
        let saved = try XCTUnwrap(ImageLoader.loadFull(url))
        XCTAssertEqual(saved.width, copied.width); XCTAssertEqual(saved.height, copied.height)
        XCTAssertEqual(editor.model.doc.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(editor.canvas.selectionRect, region)
    }

    func testExplicitMenuCopyAndShortcutStillCopyTheActiveRegion() async throws {
        let clipboard = ClipboardSnapshot()
        defer { clipboard.restore() }
        let editor = EditorHarness(tool: .select)
        defer { editor.close() }
        editor.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 140))
        let item = NSMenuItem(title: "复制", action: #selector(CanvasView.copyAction(_:)), keyEquivalent: "c")
        editor.canvas.copyAction(item)
        XCTAssertEqual(Clipboard.readImage()?.width, 160)
        XCTAssertEqual(Clipboard.readImage()?.height, 120)
        editor.model.chooseTool(.crop)
        editor.model.cropPadding = 7
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(editor.canvas.performKeyEquivalent(with: event))
        XCTAssertEqual(Clipboard.readImage()?.width, 414)
        XCTAssertEqual(Clipboard.readImage()?.height, 314)
        XCTAssertEqual(editor.model.doc.size, CGSize(width: 400, height: 300))
        XCTAssertTrue(editor.model.status.contains("裁剪区域"))
    }

    func testNativeEditorRedrawsDoNotCopy() async throws {
        let editor = EditorHarness(tool: .hand)
        defer { editor.close() }
        let count = NSPasteboard.general.changeCount
        let host = NSHostingView(rootView: EditorView(model: editor.model))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        for tool in [Tool.rect, .ellipse, .number] {
            editor.model.chooseTool(tool)
            let canvas = try XCTUnwrap(editor.model.canvas)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: 240 + point.x * canvas.zoom, y: 240 + point.y * canvas.zoom), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 40, y: 40)))
            if tool != .number { canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 220, y: 150))) }
            canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 220, y: 150)))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(NSPasteboard.general.changeCount, count)
            XCTAssertFalse(editor.model.status.contains("复制"))
        }
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            editor.model.cropPadding = 0
            editor.model.chooseTool(.crop)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            try snapshot(host, to: "/tmp/hoot-editor-crop.png")
            editor.model.chooseTool(.text)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            try snapshot(host, to: "/tmp/hoot-editor-text.png")
            let canvas = try XCTUnwrap(editor.model.canvas)
            let location = canvas.convert(CGPoint(x: 240 + 60 * canvas.zoom, y: 240 + 190 * canvas.zoom), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: event)
            let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
            field.insertText("Hoot 文字编辑", replacementRange: NSRange(location: 0, length: 0))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            try snapshot(host, to: "/tmp/hoot-editor-text-editing.png")
        }
    }

    private func snapshot(_ view: NSView, to path: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
private final class EditorHarness {
    let model: EditorModel
    let canvas: CanvasView
    private let window: NSWindow
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var documentIDs = Set<UUID>()
    private let preferenceKeys = ["textFontName", "cropPadding", "imageExportStyle"]
    private var savedPreferences: [String: Any] = [:]
    private let templateDomain = "hoot-tests-\(UUID().uuidString)"

    init(tool: Tool) {
        _ = NSApplication.shared
        for key in preferenceKeys { savedPreferences[key] = UserDefaults.standard.object(forKey: key) }
        let context = Renderer.makeContext(width: 400, height: 300)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let templates = ImageExportTemplateStore(defaults: UserDefaults(suiteName: templateDomain)!, directory: directory.appendingPathComponent("templates"))
        model = EditorModel(image: context.makeImage()!, history: HistoryStore(directory: directory), entry: nil, exportTemplates: templates)
        model.tool = tool
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        model.canvas = canvas
        canvas.attach(model)
        documentIDs.insert(model.documentID)
    }

    func close() {
        try? model.checkpoint() // Cancel the pending draft timer before removing this fixture's drafts.
        documentIDs.insert(model.documentID)
        DraftStore.close(model.sessionID)
        for id in documentIDs { DraftStore.removeDocument(id) }
        try? FileManager.default.removeItem(at: directory)
        window.close()
        UserDefaults.standard.removePersistentDomain(forName: templateDomain)
        for key in preferenceKeys {
            if let value = savedPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        documentIDs.insert(model.documentID)
        let viewPoint = CGPoint(x: 240 + point.x * canvas.zoom, y: 240 + point.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [],
                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func click(_ point: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, at: point))
        canvas.mouseUp(with: event(.leftMouseUp, at: point))
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, at: start))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end))
        canvas.mouseUp(with: event(.leftMouseUp, at: end))
    }

    func moveMouse(to point: CGPoint) { canvas.mouseMoved(with: event(.mouseMoved, at: point)) }
    func hitView(at point: CGPoint) -> NSView? {
        let viewPoint = CGPoint(x: 240 + point.x * canvas.zoom, y: 240 + point.y * canvas.zoom)
        return canvas.hitTest(canvas.convert(viewPoint, to: canvas.superview))
    }
}

@MainActor
final class ClipboardSnapshot {
    private let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
    }
    func restore() {
        let restored = items.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            return item
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(restored)
    }
}
