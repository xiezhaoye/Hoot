import AppKit
import SwiftUI
import XCTest
import ShotPadCore
@testable import ShotPad

@MainActor
final class MobileSharingTests: XCTestCase {
    func testSuccessfulPhoneCopyFinishesThenWritesFormattedPNG() async throws {
        let clipboard = ClipboardSnapshot()
        defer { clipboard.restore() }
        let service = MobileImageSharing { _ in
            XCTAssertFalse(Thread.isMainThread)
            return [RecognizedLine(text: "完整的原始文字。", rect: CGRect(x: 0, y: 0, width: 300, height: 20))]
        }
        let image = source(.white)
        var finished = false, progress: [String] = []
        try await service.copy(image, template: template(), progress: { progress.append($0) }) {
            finished = true; Clipboard.write(image) // Simulate "copy after capture".
        }
        XCTAssertTrue(finished)
        let output = try XCTUnwrap(Clipboard.readImage())
        XCTAssertEqual(output.width, 1080); XCTAssertLessThan(output.height, 500)
        XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 240)
        XCTAssertEqual(progress, ["正在识别文字…", "正在整理段落…", "正在生成手机图片…"])
    }

    func testCacheUsesPixelsAndRendersNewTemplateWithoutRepeatingOCR() async throws {
        let calls = RecognitionCounter()
        let service = MobileImageSharing { _ in
            calls.increment()
            return [RecognizedLine(text: "可重复分享的文字。", rect: CGRect(x: 0, y: 0, width: 300, height: 20))]
        }
        _ = try await service.makeImage(source(.white), template: template())
        _ = try await service.makeImage(source(.white), template: template()) // Distinct CGImages, identical pixels.
        XCTAssertEqual(calls.value, 1)
        var changed = template(); changed.style.background = .solid; changed.style.color = .black; changed.style.padding = 8
        let output = try await service.makeImage(source(.white), template: changed)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(pixel(output, x: 0, y: 0), 0)
        _ = try await service.makeImage(source(.red), template: template())
        XCTAssertEqual(calls.value, 2)
    }

    func testEmptyOCRAndInvalidTemplateDoNotFinishCaptureOrCopy() async throws {
        let count = NSPasteboard.general.changeCount
        var finished = false
        let empty = MobileImageSharing { _ in [] }
        do {
            try await empty.copy(source(.white), template: template(), beforeCopy: { finished = true })
            XCTFail("Expected a no-text failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("没有识别到文字")) }
        let calls = RecognitionCounter()
        let service = MobileImageSharing { _ in
            calls.increment()
            return [RecognizedLine(text: "正文", rect: CGRect(x: 0, y: 0, width: 80, height: 20))]
        }
        var invalid = template(); invalid.style.background = .image
        do {
            try await service.copy(source(.white), template: invalid, beforeCopy: { finished = true })
            XCTFail("Expected a missing-background failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("背景设置")) }
        XCTAssertFalse(finished)
        XCTAssertEqual(NSPasteboard.general.changeCount, count)
        _ = try await service.makeImage(source(.white), template: template())
        XCTAssertEqual(calls.value, 1) // Fixing the template can reuse the successful recognition.
    }

    func testCancellationDuringOCRNeverWritesClipboard() async throws {
        let calls = RecognitionCounter(), count = NSPasteboard.general.changeCount
        let service = MobileImageSharing { _ in
            calls.increment()
            for _ in 0..<100 { Thread.sleep(forTimeInterval: 0.01); try Task.checkCancellation() }
            return [RecognizedLine(text: "不应复制", rect: CGRect(x: 0, y: 0, width: 80, height: 20))]
        }
        var finished = false
        let image = source(.white), style = template()
        let job = Task { try await service.copy(image, template: style, beforeCopy: { finished = true }) }
        for _ in 0..<100 where calls.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(calls.value, 1)
        job.cancel()
        do { try await job.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(finished)
        XCTAssertEqual(NSPasteboard.general.changeCount, count)
    }

    func testCancellationAtRenderStageCannotCommitStaleResult() async throws {
        let service = MobileImageSharing { _ in [RecognizedLine(text: "完整文字", rect: CGRect(x: 0, y: 0, width: 80, height: 20))] }
        let count = NSPasteboard.general.changeCount
        var finished = false, job: Task<Void, Error>?
        let image = source(.white), style = template()
        job = Task {
            try await service.copy(image, template: style, progress: { message in
                if message.contains("生成") { job?.cancel() }
            }, beforeCopy: { finished = true })
        }
        do { try await job?.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(finished)
        XCTAssertEqual(NSPasteboard.general.changeCount, count)
    }

    func testProcessingTokensKeepOldJobFromUnlockingNewCapture() async throws {
        let tools = QuickToolState(), first = UUID(), second = UUID()
        var firstCancelled = false, secondCancelled = false
        tools.tool = .rect
        tools.beginProcessing(first) { firstCancelled = true }
        tools.pick(.ellipse); tools.adjustWidth(1)
        XCTAssertEqual(tools.tool, .rect); XCTAssertEqual(tools.width, 3)
        tools.beginProcessing(second) { secondCancelled = true }
        XCTAssertTrue(firstCancelled)
        tools.endProcessing(first)
        XCTAssertEqual(tools.processingID, second)
        tools.reset()
        XCTAssertTrue(secondCancelled)
        XCTAssertFalse(tools.isProcessing)
        tools.endProcessing(second)
        XCTAssertFalse(tools.isProcessing)
    }

    func testCaptureBarRendersShareMenuWithPhoneAction() async throws {
        let tools = QuickToolState()
        let actions = QuickActions(copyText: { _ in }, openURL: { _ in }, translate: {}, edit: {}, copyImage: {},
            shareImage: { true }, shareForPhone: { progress in progress("正在识别文字…"); try await Task.sleep(for: .seconds(2)) }, pin: {}, close: {})
        let panel = QuickBar.makePanel(QuickBarView(actions: actions, tools: tools))
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(panel.frame.width, 800)
        let host = try XCTUnwrap(panel.contentView)
        let popup = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
        let started = RecognitionCounter(), ended = RecognitionCounter()
        let startObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in started.increment() }
        let endObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in ended.increment() }
        defer { NotificationCenter.default.removeObserver(startObserver); NotificationCenter.default.removeObserver(endObserver) }
        var titles: [String] = []
        panel.orderFrontRegardless()
        var openedMenu: NSMenu?
        let menuTimer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let menu = popup.menu, menu.indexOfItem(withTitle: "适配手机") >= 0 else { return }
                titles = menu.items.map(\.title); openedMenu = menu
                menu.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(menuTimer, forMode: .eventTracking)
        popup.performClick(nil)
        menuTimer.invalidate()
        if let menu = openedMenu {
            let phone = menu.indexOfItem(withTitle: "适配手机")
            if phone >= 0 { menu.performActionForItem(at: phone) }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(titles.contains("原图（原尺寸）"))
        XCTAssertTrue(titles.contains("适配手机"))
        XCTAssertGreaterThan(started.value, 0)
        XCTAssertEqual(started.value, ended.value)
        XCTAssertFalse(QuickBar.isTrackingMenu)
        XCTAssertTrue(tools.isProcessing)
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hoot-mobile-progress.png"))
        }
        tools.cancelProcessing()
        for _ in 0..<50 where tools.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(tools.isProcessing)
        if ProcessInfo.processInfo.environment["HOOT_UI_SNAPSHOTS"] != nil, let host = panel.contentView {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hoot-phone-share-menu.png"))
        }
    }

    private func source(_ color: RGBA) -> CGImage {
        let ctx = Renderer.makeContext(width: 320, height: 240)
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        return ctx.makeImage()!
    }
    private func template() -> ImageExportTemplate { ImageExportTemplate(name: "测试模板", style: ImageExportStyle()) }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let ctx = Renderer.makeContext(width: 1, height: 1)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return ctx.data!.bindMemory(to: UInt8.self, capacity: 4)[0]
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

private final class RecognitionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
