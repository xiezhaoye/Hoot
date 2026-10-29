import AppKit
import XCTest
import ShotPadCore
@testable import ShotPad

@MainActor
final class CapturePreviewTests: XCTestCase {
    func testSharedResultRemainsSelectedAndCopyKeepsAllPixels() async throws {
        let clipboard = ClipboardSnapshot(); defer { clipboard.restore() }
        let fixture = try PreviewFixture(); defer { fixture.close() }
        let image = previewImage(width: 1080, height: 5000)
        var selections = 0, layouts = 0
        fixture.view.onSelect = { _ in selections += 1 }
        fixture.view.onPresentationChange = { _ in layouts += 1 }
        fixture.view.showSharedResult(image)
        XCTAssertTrue(fixture.view.hasSelection)
        XCTAssertTrue(fixture.view.isShowingSharedResult)
        XCTAssertTrue(fixture.window.contentView === fixture.view)
        XCTAssertNotNil(fixture.view.sharedResultFrame)
        XCTAssertEqual(selections, 0) // Do not recreate the floating action bar and cancel its current task.
        XCTAssertGreaterThan(layouts, 0)
        XCTAssertTrue(fixture.view.copySelection())
        let copied = try XCTUnwrap(Clipboard.readImage())
        XCTAssertEqual(copied.width, 1080); XCTAssertEqual(copied.height, 5000)
        XCTAssertEqual(pixel(copied, 500, 4900).1, 255)
    }

    func testResultCanBeAnnotatedAndUndoneInOriginalPixelCoordinates() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 1080, height: 5000))
        fixture.tools.pick(.rect)
        fixture.dragPixels(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 400, y: 600))
        let edited = try XCTUnwrap(fixture.view.annotatedImage)
        XCTAssertEqual(edited.width, 1080); XCTAssertEqual(edited.height, 5000)
        XCTAssertLessThan(pixel(edited, 100, 450).1, 100)
        XCTAssertTrue(fixture.tools.canUndo)
        fixture.tools.undo()
        let restored = try XCTUnwrap(fixture.view.annotatedImage)
        XCTAssertEqual(pixel(restored, 100, 450).1, 255)
        XCTAssertTrue(fixture.view.hasSelection)
    }

    func testMovingResizingAndZoomingOnlyChangePreviewNotExport() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 640, height: 480))
        let original = try XCTUnwrap(fixture.view.sharedResultFrame)
        fixture.dragView(from: CGPoint(x: original.midX, y: original.midY), to: CGPoint(x: original.midX + 20, y: original.midY + 20))
        let moved = try XCTUnwrap(fixture.view.sharedResultFrame)
        XCTAssertNotEqual(moved.origin, original.origin)
        let corner = Handle.bottomRight.point(in: moved)
        fixture.dragView(from: corner, to: CGPoint(x: corner.x + 30, y: corner.y + 22.5))
        let resized = try XCTUnwrap(fixture.view.sharedResultFrame)
        XCTAssertGreaterThan(resized.width, moved.width)
        XCTAssertEqual(resized.width / resized.height, 640.0 / 480, accuracy: 0.0001)
        fixture.zoomIn()
        XCTAssertGreaterThan(try XCTUnwrap(fixture.view.sharedResultFrame).width, resized.width)
        XCTAssertEqual(fixture.view.annotatedImage?.width, 640)
        XCTAssertEqual(fixture.view.annotatedImage?.height, 480)
        XCTAssertTrue(fixture.view.hasSelection)
    }

    func testPasteIntoResultUsesImageCoordinatesWhenMouseIsOutsidePreview() async throws {
        let clipboard = ClipboardSnapshot(); defer { clipboard.restore() }
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 640, height: 1200))
        fixture.zoomIn()
        fixture.window.setFrameOrigin(CGPoint(x: NSEvent.mouseLocation.x + 10000, y: NSEvent.mouseLocation.y + 10000))
        let ctx = Renderer.makeContext(width: 40, height: 40)
        ctx.setFillColor(RGBA.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        Clipboard.write(try XCTUnwrap(ctx.makeImage()))
        XCTAssertTrue(fixture.view.pasteImage())
        let edited = try XCTUnwrap(fixture.view.annotatedImage)
        XCTAssertLessThan(pixel(edited, 320, 600).1, 100)
        XCTAssertEqual(pixel(edited, 320, 200).1, 255)
        XCTAssertTrue(fixture.view.hasSelection)
    }

    func testClipboardActionsGiveFeedbackAndKeepEditorOpen() async throws {
        let clipboard = ClipboardSnapshot(); defer { clipboard.restore() }
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 640, height: 800))
        fixture.tools.copy()
        XCTAssertEqual(fixture.tools.editStatus, "已复制图片")
        fixture.tools.paste()
        XCTAssertEqual(fixture.tools.editStatus, "已粘贴，可移动和缩放")
        XCTAssertNotNil(fixture.view.doc?.patch)
        XCTAssertTrue(fixture.view.hasSelection)
    }

    func testTextCanBeAddedAndReeditedAfterZoomWithoutChangingFontPixels() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 640, height: 1200))
        fixture.tools.pick(.text)
        fixture.clickPixel(CGPoint(x: 200, y: 600))
        let field = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? NSTextView }.first)
        field.string = "浮层文字"
        fixture.view.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        let originalSize = try XCTUnwrap(field.font).pointSize * fixture.pixelsPerPoint
        for _ in 0..<6 { fixture.zoomIn() }
        XCTAssertNil(fixture.view.subviews.compactMap { $0 as? NSTextView }.first)
        fixture.clickPixel(CGPoint(x: 220, y: 600 + originalSize * 0.6), clicks: 2)
        let editor = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(editor.string, "浮层文字")
        XCTAssertEqual(try XCTUnwrap(editor.font).pointSize * fixture.pixelsPerPoint, originalSize, accuracy: 0.01)
    }

    func testSelectedShapeInteriorMovesRepeatedlyAndToolChangeFixesIt() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 800, height: 800))
        fixture.tools.pick(.rect)
        fixture.dragPixels(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
        let id = try XCTUnwrap(fixture.view.doc?.state.annotations.first?.id)
        fixture.clickPixel(CGPoint(x: 200, y: 200))
        fixture.dragPixels(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 240, y: 240))
        fixture.dragPixels(from: CGPoint(x: 240, y: 240), to: CGPoint(x: 270, y: 250))
        let moved = try XCTUnwrap(fixture.view.doc?.annotation(id)?.bounds)
        XCTAssertEqual(moved.midX, 270, accuracy: 2); XCTAssertEqual(moved.midY, 250, accuracy: 2)
        fixture.tools.pick(.ellipse)
        XCTAssertNil(fixture.view.doc?.annotation(id))
        fixture.tools.undo()
        XCTAssertNotNil(fixture.view.doc?.annotation(id))
    }

    func testSelectionMovesOnFirstDragAndCanResizeAfterwards() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 800, height: 800))
        fixture.tools.pick(.select)
        fixture.dragPixels(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
        fixture.dragPixels(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 250, y: 240))
        let moved = try XCTUnwrap(fixture.view.doc?.patch?.rect)
        XCTAssertEqual(moved.minX, 150, accuracy: 2); XCTAssertEqual(moved.minY, 140, accuracy: 2)
        fixture.dragPixels(from: CGPoint(x: moved.maxX, y: moved.maxY), to: CGPoint(x: moved.maxX + 40, y: moved.maxY + 40))
        XCTAssertGreaterThan(try XCTUnwrap(fixture.view.doc?.patch?.rect.width), moved.width)
    }

    func testLiveTextSupportsMultipleLinesAndCornerResize() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.view.showSharedResult(previewImage(width: 800, height: 800))
        fixture.tools.pick(.text)
        fixture.clickPixel(CGPoint(x: 200, y: 200))
        let field = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? NSTextView }.first)
        field.string = "第一行\n第二行"
        fixture.view.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        let original = try XCTUnwrap(field.font).pointSize
        let bottomRight = CGPoint(x: field.frame.maxX + 4, y: field.frame.maxY + 4)
        fixture.dragView(from: bottomRight, to: CGPoint(x: bottomRight.x + 40, y: bottomRight.y + 40))
        XCTAssertGreaterThan(try XCTUnwrap(field.font).pointSize, original)
        let resized = try XCTUnwrap(field.font).pointSize
        fixture.tools.color = .black
        XCTAssertEqual(try XCTUnwrap(field.font).pointSize, resized, accuracy: 0.01)
        fixture.tools.pick(.rect)
        XCTAssertNil(fixture.view.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertNotNil(fixture.view.annotatedImage)
    }

    func testRawCaptureEditsRemainWithinSelectedRegion() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        fixture.dragView(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 500))
        XCTAssertTrue(fixture.view.hasSelection)
        fixture.tools.pick(.select)
        fixture.dragView(from: CGPoint(x: 180, y: 180), to: CGPoint(x: 260, y: 260))
        fixture.dragView(from: CGPoint(x: 220, y: 220), to: CGPoint(x: 700, y: 700))
        let block = try XCTUnwrap(fixture.view.doc?.patch)
        let scale = fixture.view.shot.scale
        XCTAssertLessThanOrEqual(block.rect.maxX, 500 * scale + 1)
        XCTAssertLessThanOrEqual(block.rect.maxY, 500 * scale + 1)
        XCTAssertTrue(fixture.view.hasSelection)
    }

    func testNativeResultPreviewDrawsCurrentImageAndSelectedFrame() async throws {
        let fixture = try PreviewFixture(); defer { fixture.close() }
        let image = try MobileTextRenderer.render([
            TextParagraph("手机分享结果仍可编辑", kind: .heading),
            TextParagraph("生成后的图片直接留在原截图浮层，蓝色选框保持选中。可以继续画矩形、箭头，或者输入文字，再复制编辑后的最新结果。"),
            TextParagraph("长图可以滚动查看，按住 Command 滚轮或捏合放大。预览大小变化不会缩小导出的图片分辨率。")
        ], style: ImageExportStyle())
        fixture.view.showSharedResult(image)
        fixture.tools.pick(.rect)
        fixture.dragPixels(from: CGPoint(x: 70, y: 180), to: CGPoint(x: 1000, y: 470))
        XCTAssertTrue(fixture.view.hasSelection)
        XCTAssertEqual(fixture.view.annotatedImage?.width, 1080)
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            let rep = try XCTUnwrap(fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds))
            fixture.view.cacheDisplay(in: fixture.view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hoot-capture-result-preview.png"))
        }
    }

    func testBothShareMenuActionsKeepFloatingEditorAlive() async throws {
        let clipboard = ClipboardSnapshot(); defer { clipboard.restore() }
        let fixture = try PreviewFixture(); defer { fixture.close() }
        let original = previewImage(width: 640, height: 480), phone = previewImage(width: 1080, height: 2400)
        var closed = 0
        let actions = QuickActions(copyText: { _ in }, openURL: { _ in }, translate: {}, edit: {}, copyImage: {},
            shareImage: { fixture.view.showSharedResult(original); Clipboard.write(original); return true },
            shareForPhone: { _ in fixture.view.showSharedResult(phone); Clipboard.write(phone) }, pin: {}, close: { closed += 1 }, dismissAfterShare: false)
        let panel = QuickBar.makePanel(QuickBarView(actions: actions, tools: fixture.tools))
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(80))
        let host = try XCTUnwrap(panel.contentView)
        let popup = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
        var menu: NSMenu?
        panel.orderFrontRegardless()
        let menuTimer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let opened = popup.menu, opened.indexOfItem(withTitle: "原图（原尺寸）") >= 0 else { return }
                menu = opened; opened.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(menuTimer, forMode: .eventTracking)
        popup.performClick(nil)
        menuTimer.invalidate()
        if let index = menu?.indexOfItem(withTitle: "原图（原尺寸）"), index >= 0 { menu?.performActionForItem(at: index) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(fixture.view.hasSelection)
        XCTAssertEqual(Clipboard.readImage()?.width, 640)
        let phoneIndex = try XCTUnwrap(menu).indexOfItem(withTitle: "适配手机")
        XCTAssertGreaterThanOrEqual(phoneIndex, 0)
        if phoneIndex >= 0 { menu?.performActionForItem(at: phoneIndex) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(fixture.view.hasSelection)
        XCTAssertEqual(fixture.view.annotatedImage?.width, 1080)
        XCTAssertEqual(Clipboard.readImage()?.height, 2400)
        XCTAssertTrue(panel.isVisible)
    }

    private func previewImage(width: Int, height: Int) -> CGImage {
        let ctx = Renderer.makeContext(width: width, height: height)
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let ctx = Renderer.makeContext(width: 1, height: 1)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
        return (data[0], data[1], data[2])
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

@MainActor
private final class PreviewFixture {
    let tools = QuickToolState()
    let view: OverlayView
    let window: NSWindow
    var pixelsPerPoint: CGFloat { CGFloat(view.annotatedImage!.width) / view.sharedResultFrame!.width }
    init() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let context = Renderer.makeContext(width: 800, height: 600)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        view = OverlayView(shot: ScreenShot(screen: screen, image: context.makeImage()!), windows: [], ownRegions: [], tools: tools)
        window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
    }
    func close() { window.close() }
    func viewPoint(_ pixel: CGPoint) -> CGPoint {
        let r = view.sharedResultFrame!
        return CGPoint(x: r.minX + pixel.x / pixelsPerPoint, y: r.minY + pixel.y / pixelsPerPoint)
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func clickPixel(_ point: CGPoint, clicks: Int = 1) {
        let p = viewPoint(point)
        view.mouseDown(with: event(.leftMouseDown, at: p, clicks: clicks)); view.mouseUp(with: event(.leftMouseUp, at: p, clicks: clicks))
    }
    func dragPixels(from start: CGPoint, to end: CGPoint) { dragView(from: viewPoint(start), to: viewPoint(end)) }
    func dragView(from start: CGPoint, to end: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, at: start))
        view.mouseDragged(with: event(.leftMouseDragged, at: end))
        view.mouseUp(with: event(.leftMouseUp, at: end))
    }
    func zoomIn() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24)!
        view.keyDown(with: event)
    }
}
