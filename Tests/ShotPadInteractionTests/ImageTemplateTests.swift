import AppKit
import SwiftUI
import XCTest
import ShotPadCore
@testable import ShotPad

@MainActor
final class ImageTemplateTests: XCTestCase {
    func testLegacyStyleAndBackgroundMigrateAndKeepStableIDs() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        var style = ImageExportStyle(); style.padding = 17; style.cornerRadius = 7; style.shadow = false
        let png = try XCTUnwrap(templateImage(.black).pngData)
        fixture.defaults.set(try JSONEncoder().encode(style), forKey: "imageExportStyle")
        try png.write(to: fixture.directory.appendingPathComponent("ExportBackground.png"))
        let store = fixture.store()
        XCTAssertEqual(store.library.defaultTemplate.style, style)
        XCTAssertEqual(store.library.defaultTemplate.backgroundPNG, png)
        let restored = fixture.store()
        XCTAssertEqual(restored.library, store.library)
        XCTAssertEqual(restored.workingStyle, style)
        XCTAssertEqual(restored.workingBackgroundPNG, png)
    }

    func testCaptureSharingUsesDefaultRatherThanSelectedAndWritesAfterAutomaticCopy() async throws {
        let clipboard = ClipboardSnapshot()
        defer { clipboard.restore() }
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let store = fixture.store(), first = store.library.defaultID
        var style = ImageExportStyle(); style.padding = 5; style.cornerRadius = 0; style.shadow = false
        let compact = try store.save(name: "紧凑", style: style, backgroundPNG: nil)
        XCTAssertEqual(store.library.selectedID, compact.id)
        XCTAssertEqual(store.library.defaultID, first)
        let image = templateImage(.red)
        var finished = false
        XCTAssertTrue(CaptureImageSharing.copy(image, templates: store) { finished = true; Clipboard.write(image) })
        XCTAssertTrue(finished)
        XCTAssertEqual(Clipboard.readImage()?.width, 84) // 20 + default 32 px on each side
        XCTAssertEqual(Clipboard.readImage()?.height, 74)
        try store.save(id: compact.id, name: compact.name, style: style, backgroundPNG: nil, makeDefault: true)
        XCTAssertTrue(CaptureImageSharing.copy(image, templates: store))
        XCTAssertEqual(Clipboard.readImage()?.width, 30)
        XCTAssertEqual(Clipboard.readImage()?.height, 20)
        XCTAssertLessThan(sample(try XCTUnwrap(Clipboard.readImage()), x: 10, y: 10).1, 80) // screenshot content stays red
        XCTAssertEqual(fixture.store().library.defaultTemplate.id, compact.id)
    }

    func testInvalidDefaultKeepsCaptureAndPasteboardUntouched() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        var invalid = ImageExportStyle(); invalid.background = .image
        fixture.defaults.set(try JSONEncoder().encode(invalid), forKey: "imageExportStyle")
        let store = fixture.store(), count = NSPasteboard.general.changeCount
        var finished = false
        XCTAssertFalse(CaptureImageSharing.copy(templateImage(.white), templates: store) { finished = true })
        XCTAssertFalse(finished)
        XCTAssertEqual(NSPasteboard.general.changeCount, count)
    }

    func testModelSaveAsModifySetDefaultAndSwitchRoundtrip() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let store = fixture.store(), model = fixture.model(store)
        let original = model.selectedExportTemplateID
        model.exportStyle.padding = 9
        XCTAssertTrue(model.exportTemplateModified)
        XCTAssertTrue(model.saveExportTemplate(name: "我的模板"))
        let custom = model.selectedExportTemplateID
        XCTAssertNotEqual(custom, original)
        XCTAssertEqual(store.library.defaultID, original)
        XCTAssertFalse(model.exportTemplateModified)
        model.exportStyle.padding = 13
        XCTAssertEqual(store.library.templates.first { $0.id == custom }?.style.padding, 9)
        XCTAssertTrue(model.saveExportTemplate(makeDefault: true))
        XCTAssertEqual(store.library.defaultTemplate.style.padding, 13)
        model.selectExportTemplate(original)
        XCTAssertEqual(model.exportStyle.padding, 32)
        XCTAssertFalse(model.exportTemplateModified)
        XCTAssertEqual(store.library.defaultID, custom)
        let restored = fixture.model(fixture.store())
        XCTAssertEqual(restored.selectedExportTemplateID, original)
        XCTAssertEqual(restored.exportStyle.padding, 32)
    }

    func testTemplatesOwnIndependentImagesAcrossSwitchesAndRestart() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let store = fixture.store()
        var style = ImageExportStyle(); style.background = .image; style.padding = 10; style.shadow = false; style.cornerRadius = 0
        let black = try XCTUnwrap(templateImage(.black).pngData), red = try XCTUnwrap(templateImage(.red).pngData)
        let a = try store.save(name: "黑色背景", style: style, backgroundPNG: black, makeDefault: true)
        let b = try store.save(name: "红色背景", style: style, backgroundPNG: red)
        let model = fixture.model(store)
        model.selectExportTemplate(a.id)
        XCTAssertEqual(model.exportBackgroundPNG, black)
        XCTAssertFalse(model.exportTemplateModified)
        model.selectExportTemplate(b.id)
        XCTAssertEqual(model.exportBackgroundPNG, red)
        XCTAssertFalse(model.exportTemplateModified)
        let restored = fixture.store()
        XCTAssertEqual(restored.library.templates.first { $0.id == a.id }?.backgroundPNG, black)
        XCTAssertEqual(restored.library.templates.first { $0.id == b.id }?.backgroundPNG, red)
        let output = try XCTUnwrap(restored.renderDefault(templateImage(.white)))
        XCTAssertEqual(sample(output, x: 0, y: 0).0, 0)
        let restoredModel = fixture.model(restored)
        XCTAssertEqual(restoredModel.exportBackgroundPNG, red)
    }

    func testInvalidNamesMissingBackgroundAndWriteFailureDoNotChangeLibrary() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let store = fixture.store(), original = store.library
        XCTAssertThrowsError(try store.save(name: "  ", style: ImageExportStyle(), backgroundPNG: nil))
        XCTAssertThrowsError(try store.save(name: original.defaultTemplate.name, style: ImageExportStyle(), backgroundPNG: nil))
        var image = ImageExportStyle(); image.background = .image
        XCTAssertThrowsError(try store.save(name: "缺少图片", style: image, backgroundPNG: nil))
        XCTAssertEqual(store.library, original)
        let blocked = fixture.directory.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        let readOnly = ImageExportTemplateStore(defaults: fixture.defaults, directory: blocked)
        let before = readOnly.library
        XCTAssertThrowsError(try readOnly.save(name: "无法写入", style: ImageExportStyle(), backgroundPNG: nil))
        XCTAssertEqual(readOnly.library, before)
    }

    func testRenameDeleteDefaultAndRecoverableBackup() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let store = fixture.store(), first = store.library.defaultTemplate
        try store.rename(first.id, to: "温暖默认")
        XCTAssertEqual(store.library.defaultTemplate.name, "温暖默认")
        XCTAssertEqual(store.library.defaultTemplate.style, first.style)
        try store.remove(first.id)
        XCTAssertNotEqual(store.library.defaultID, first.id)
        XCTAssertEqual(store.library.selectedID, store.library.defaultID)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.deleted, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = try PropertyListDecoder().decode(ImageExportTemplate.self, from: Data(contentsOf: backups[0]))
        XCTAssertEqual(backup.id, first.id)
        XCTAssertEqual(backup.name, "温暖默认")
        while store.library.templates.count > 1 { try store.remove(store.library.templates[0].id) }
        XCTAssertThrowsError(try store.remove(store.library.templates[0].id))
        XCTAssertEqual(store.library.templates.count, 1)
        XCTAssertTrue(store.library.isValid)
        XCTAssertEqual(fixture.store().library, store.library)
    }

    func testMultipleEditorsPersistMatchingTemplateStyleAndImage() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let store = fixture.store()
        var style = ImageExportStyle(); style.background = .image; style.padding = 10
        let black = try XCTUnwrap(templateImage(.black).pngData), red = try XCTUnwrap(templateImage(.red).pngData)
        let a = try store.save(name: "背景 A", style: style, backgroundPNG: black, makeDefault: true)
        let b = try store.save(name: "背景 B", style: style, backgroundPNG: red)
        let first = fixture.model(store), second = fixture.model(store)
        first.selectExportTemplate(a.id); second.selectExportTemplate(b.id)
        first.exportStyle.padding = 27
        let restored = fixture.model(fixture.store())
        XCTAssertEqual(restored.selectedExportTemplateID, a.id)
        XCTAssertEqual(restored.exportStyle.padding, 27)
        XCTAssertEqual(restored.exportBackgroundPNG, black)
        XCTAssertEqual(store.library.defaultTemplate.style.padding, 10)
        XCTAssertTrue(second.saveExportTemplate(name: "背景 B 副本"))
        let restoredSecond = fixture.model(fixture.store())
        XCTAssertEqual(restoredSecond.selectedExportTemplateID, second.selectedExportTemplateID)
        XCTAssertEqual(restoredSecond.exportStyle.padding, 10)
        XCTAssertEqual(restoredSecond.exportBackgroundPNG, red)
    }

    func testNativeTemplatePanelAndCaptureBarRender() async throws {
        let fixture = TemplateFixture()
        defer { fixture.close() }
        let model = fixture.model(fixture.store())
        let host = NSHostingView(rootView: ImageExportInspector(model: model).padding(18).background(EditorStyle.panel))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 228, height: 850), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let actions = QuickActions(copyText: { _ in }, openURL: { _ in }, translate: {}, edit: {}, copyImage: {}, shareImage: { true }, pin: {}, close: {})
        let bar = QuickBar.makePanel(QuickBarView(actions: actions))
        defer { bar.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(bar.frame.width, 800)
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            try snapshot(host, to: "/tmp/hoot-template-panel.png")
            try snapshot(try XCTUnwrap(bar.contentView), to: "/tmp/hoot-capture-actions.png")
        }
    }

    private func templateImage(_ color: RGBA) -> CGImage {
        let ctx = Renderer.makeContext(width: 20, height: 10)
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        return ctx.makeImage()!
    }
    private func sample(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        let ctx = Renderer.makeContext(width: 1, height: 1)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
    private func snapshot(_ view: NSView, to path: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
private final class TemplateFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-templates-\(UUID().uuidString)")
    let domain = "hoot-template-tests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: domain)! }
    var deleted: URL { directory.appendingPathComponent("deleted") }
    init() { _ = NSApplication.shared; try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func store() -> ImageExportTemplateStore {
        ImageExportTemplateStore(defaults: defaults, directory: directory, trashTemplate: { [self] source in
            try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: deleted.appendingPathComponent(source.lastPathComponent))
        })
    }
    func model(_ store: ImageExportTemplateStore) -> EditorModel {
        EditorModel(image: Board.blank(size: CGSize(width: 200, height: 100))!,
                    history: HistoryStore(directory: directory.appendingPathComponent("history")), entry: nil, exportTemplates: store)
    }
    func close() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }
}
