import AppKit
import SwiftUI
import ShotPadCore

/// Draw the supplied transparent artwork directly in the live Dock tile.
private final class HootDockIcon: NSView {
    private let image: NSImage
    init(image: NSImage) { self.image = image; super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128)); autoresizingMask = [.width, .height] }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: EditorModel
    var onClose: ((EditorWindowController) -> Void)?

    init(image shot: CGImage, history: HistoryStore, entry: HistoryEntry?, board: Bool = false) {
        let doc = Self.makeDocument(shot: shot, entry: entry, board: board)
        let image = doc.state.base
        model = EditorModel(image: image, history: history, entry: entry)
        model.doc = doc
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let w = min(max(CGFloat(image.width) / scale + 480, 1240), visible.width * 0.92)
        let h = min(max(CGFloat(image.height) / scale + 130, 800), visible.height * 0.92)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Hoot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let titlebarSpace = NSTitlebarAccessoryViewController()
        titlebarSpace.layoutAttribute = .bottom
        titlebarSpace.view = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 42))
        window.addTitlebarAccessoryViewController(titlebarSpace)
        window.minSize = CGSize(width: 980, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: EditorView(model: model))
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.center()
    }

    /// A board holds the shot floating in its middle (selected, movable as one piece); otherwise the entry's draft or plain image.
    static func makeDocument(shot: CGImage, entry: HistoryEntry?, board: Bool) -> EditorDocument {
        guard board else { return entry.flatMap { DraftStore.load($0.id) } ?? EditorDocument(image: shot) }
        let size = Board.size(for: CGSize(width: shot.width, height: shot.height), default: AppSettings.shared.boardSize)
        let blank = Board.blank(size: size) ?? shot
        let doc = EditorDocument(image: blank)
        doc.paste(shot, centeredAt: CGPoint(x: CGFloat(blank.width) / 2, y: CGFloat(blank.height) / 2))
        return doc
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (NSApp.delegate as? AppDelegate)?.isTerminating == true { return }
        model.persistCurrent()
        DraftStore.close(model.sessionID)
        onClose?(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var isTerminating = false
    private var statusItem: NSStatusItem!
    private var capturePending = false
    private var captureItem: NSMenuItem?
    private var saveItem: NSMenuItem?
    private var pendingEdit: (() -> Void)?

    func updateSaveShortcut() {
        guard let item = saveItem else { return }
        let s = AppSettings.shared
        let special = ["↩": "\r", "⇥": "\t", "空格": " ", "⌫": "\u{8}", "←": "\u{f702}", "→": "\u{f703}", "↓": "\u{f701}", "↑": "\u{f700}"]
        item.keyEquivalent = special[s.saveKeyLabel] ?? (s.saveKeyLabel.count == 1 ? s.saveKeyLabel.lowercased() : "")
        var mask: NSEvent.ModifierFlags = []
        if s.saveModifiers & 4096 != 0 { mask.insert(.control) }
        if s.saveModifiers & 2048 != 0 { mask.insert(.option) }
        if s.saveModifiers & 512 != 0 { mask.insert(.shift) }
        if s.saveModifiers & 256 != 0 { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }
    private var editors: [EditorWindowController] = []
    private let history = HistoryStore(directory: Settings.historyDirectory, limit: Settings.historyLimit)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = Bundle.main.image(forResource: "dock-icon") {
            NSApp.applicationIconImage = image
            NSApp.dockTile.contentView = HootDockIcon(image: image)
            NSApp.dockTile.display()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Hoot")
        statusItem.menu = makeMenu()
        PinWindow.onEdit = { [weak self] image in
            guard let self, let entry = self.saveToHistory(CaptureResult(image: image, screenRect: .zero)) else { return }
            self.openEditor(image: image, entry: entry, board: true)
        }
        registerCaptureHotKey()
        HotKey.register(keyCode: 35, modifiers: 4096 | 2048, id: 2) { [weak self] in self?.pinClipboard() } // ⌃⌥P
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        TextTools.warmUp()
        ScreenCapture.warmUp()
        NSApp.mainMenu = makeMainMenu()
        refreshPolicy()
        let sessions = DraftStore.sessions()
        var restored = false
        for session in sessions {
            guard let doc = DraftStore.load(session.documentID) else { continue }
            // Untouched shots live in the history anyway; only reopen windows that hold real edits.
            guard doc.isModified else { DraftStore.close(session.id); continue }
            let entry = history.entries.first { $0.id == session.historyID }
            // Only one main window: further unsaved edits go straight into the history.
            if !editors.isEmpty {
                if let id = session.historyID, entry != nil { history.update(id, with: doc.flattened()) }
                else { history.add(doc.flattened(), format: AppSettings.shared.imageFormat, namePrefix: "画板") }
                DraftStore.close(session.id); continue
            }
            let controller = openEditor(image: doc.state.base, entry: entry)
            controller.model.doc = doc
            controller.model.canvas?.reload(resetScroll: true)
            controller.model.tool = session.tool.flatMap(Tool.init(rawValue:)) ?? .hand
            controller.model.savedURL = session.savedURL
            controller.model.restoredView = (session.zoom, session.scrollOrigin)
            DispatchQueue.main.async { controller.model.canvas?.restoreViewport() }
            if !session.frame.isEmpty {
                let frame = NSRectFromString(session.frame)
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { controller.window.setFrame(frame, display: true) }
            }
            do { try controller.model.checkpoint(); DraftStore.close(session.id); restored = true }
            catch { controller.model.status = "恢复成功，但草稿暂时无法写入"; restored = true }
        }
        if !restored && editors.isEmpty && AppSettings.shared.openMainOnLaunch { openMain() }
        UpdateManager.shared.start()
    }

    func checkpointEditors() throws {
        for editor in editors {
            editor.model.canvas?.finishTextEditing()
            editor.model.persistCurrent()
            try editor.model.checkpoint()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try checkpointEditors(); isTerminating = true; return .terminateNow }
        catch {
            let alert = NSAlert(); alert.messageText = "无法保存编辑草稿"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "返回画板"); alert.runModal(); return .terminateCancel
        }
    }

    /// The editor is the main window: open the latest shot, or a blank white canvas when there is no history.
    private func openMain() {
        if let entry = history.entries.first, let image = history.image(for: entry.id) {
            openEditor(image: image, entry: entry)
        } else if let blank = Self.blankCanvas() {
            openEditor(image: blank, entry: nil)
        }
    }

    private static func blankCanvas() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        return ctx.makeImage()
    }

    func registerCaptureHotKey() {
        let s = AppSettings.shared
        HotKey.register(keyCode: s.captureKeyCode, modifiers: s.captureModifiers, id: 1) { [weak self] in self?.capture() }
        captureItem?.title = "截图  \(s.captureShortcutText)"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click with no window open: bring up the latest shot, or the settings if there is none.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && editors.isEmpty { openMain() }
        return true
    }

    /// Dock icon + menu bar are always on, or only while an editor / settings window is open.
    func refreshPolicy() {
        let wanted = AppSettings.shared.alwaysInDock || !editors.isEmpty || SettingsWindow.isVisible
        NSApp.setActivationPolicy(wanted ? .regular : .accessory)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        let capture = item("截图", #selector(captureAction))
        capture.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")
        app.addItem(capture)
        let prefs = item("设置…", #selector(openSettings)); prefs.keyEquivalent = ","
        app.addItem(prefs)
        app.addItem(.separator())
        let quit = item("退出 Hoot", #selector(NSApplication.terminate(_:)), target: NSApp); quit.keyEquivalent = "q"
        app.addItem(quit)
        appItem.submenu = app
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "文件")
        let save = item("保存…", #selector(saveCurrent)); saveItem = save; file.addItem(save); updateSaveShortcut()
        let fix = item("固定全部", #selector(fixCurrent)); fix.keyEquivalent = "f"; fix.keyEquivalentModifierMask = [.command, .shift]; file.addItem(fix)
        fileItem.submenu = file
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        for (title, sel, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
                                  ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: sel, keyEquivalent: key)
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = edit
        return main
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let cap = item("截图  \(AppSettings.shared.captureShortcutText)", #selector(captureAction))
        cap.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图")
        captureItem = cap
        menu.addItem(cap)
        menu.addItem(item("钉住剪贴板  ⌃⌥P", #selector(pinAction)))
        menu.addItem(item("打开最近一张", #selector(openLatest)))
        let limits = NSMenuItem(title: "历史保留数量", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for n in [20, 50, 100, 200] {
            let it = item("\(n) 张", #selector(setLimit(_:)))
            it.tag = n
            it.state = n == Settings.historyLimit ? .on : .off
            sub.addItem(it)
        }
        limits.submenu = sub
        menu.addItem(limits)
        menu.addItem(item("设置…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(NSApplication.terminate(_:)), target: NSApp))
        return menu
    }

    private func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = target ?? self
        return it
    }

    private var activeEditor: EditorWindowController? { editors.first { $0.window.isKeyWindow } ?? editors.first { $0.window.isMainWindow } }
    @objc private func saveCurrent() { activeEditor?.model.saveAs() }
    @objc private func fixCurrent() { activeEditor?.model.fixAll() }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func captureAction() { capture() }
    @objc private func pinAction() { pinClipboard() }

    @objc private func setLimit(_ sender: NSMenuItem) {
        Settings.historyLimit = sender.tag
        history.limit = sender.tag
        statusItem.menu = makeMenu()
    }

    @objc private func openLatest() {
        guard let entry = history.entries.first, let image = history.image(for: entry.id) else { return }
        openEditor(image: image, entry: entry)
    }

    private func pinClipboard() {
        if let image = Clipboard.readImage() { PinWindow.show(image) } else { NSSound.beep() }
    }

    private func historyChanged() {
        editors.forEach { $0.model.entries = history.entries }
    }

    /// Ends the capture overlay. A shot only enters the history when it goes to the editor; copying, pinning,
    /// text extraction and translation leave no file behind (unless the main window is set to open after every capture).
    private func finishCapture(_ result: CaptureResult, copyingImage: Bool = true) {
        CaptureOverlay.shared.end()
        QuickBar.dismiss()
        if copyingImage && AppSettings.shared.copyAfterCapture { Clipboard.write(result.image) }
        if AppSettings.shared.openMainAfterCapture, let entry = saveToHistory(result) { openEditor(image: result.image, entry: entry) }
    }

    /// Files the shot in the history (the "编辑" path: edit button or Return).
    private func saveToHistory(_ result: CaptureResult) -> HistoryEntry? {
        let entry = history.add(result.image, format: AppSettings.shared.imageFormat)
        historyChanged()
        return entry
    }

    private func showQuickBar(for result: CaptureResult) {
        let image = result.image
        // what the user drew on the region so far is part of the shot from here on
        let current = { CaptureResult(image: CaptureOverlay.shared.annotatedImage() ?? image, screenRect: CaptureOverlay.shared.selectedScreenRect ?? result.screenRect) }
        let edit = { [weak self] in
            let shot = current()
            guard let self else { return }
            CaptureOverlay.shared.end(); QuickBar.dismiss()
            if AppSettings.shared.copyAfterCapture { Clipboard.write(shot.image) }
            guard let entry = self.saveToHistory(shot) else { return }
            self.openEditor(image: shot.image, entry: entry, board: true)
        }
        pendingEdit = edit
        let actions = QuickActions(
            copyText: { [weak self] report in
                let shot = current()
                self?.finishCapture(shot)
                Task { @MainActor in
                    do {
                        let text = try await TextTools.extractText(shot.image)
                        if text.isEmpty { report("没有识别到文字"); return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        report("已复制 \(text.count) 字")
                    } catch { report("识别失败") }
                }
            },
            openURL: { [weak self] report in
                let shot = current()
                self?.finishCapture(shot)
                Task { @MainActor in
                    if let url = await TextTools.findURL(shot.image) { NSWorkspace.shared.open(url); report("已打开") }
                    else { report("没有发现网址"); NSSound.beep() }
                }
            },
            translate: { [weak self] in
                let shot = current()
                self?.finishCapture(shot)
                TextTools.showTranslation(shot.image, toChinese: nil) { _ in }
            },
            edit: edit,
            copyImage: { [weak self] in let shot = current(); self?.finishCapture(shot); Clipboard.write(shot.image) },
            shareImage: {
                let shot = current()
                if CaptureOverlay.shared.isShowingSharedResult {
                    Clipboard.write(shot.image); return true
                }
                guard let rendered = ImageExportTemplateStore.shared.renderDefault(shot.image),
                      CaptureOverlay.shared.showSharedResult(rendered) else { return false }
                Clipboard.write(rendered); return true
            },
            shareForPhone: { progress in
                let shot = current()
                let template = ImageExportTemplateStore.shared.library.defaultTemplate
                let output = try await MobileImageSharing.shared.prepare(shot.image, template: template, progress: progress)
                try Task.checkCancellation()
                guard CaptureOverlay.shared.showSharedResult(output.image) else { throw CancellationError() }
                Clipboard.writePNG(output.png)
            },
            pin: { [weak self] in let shot = current(); self?.finishCapture(shot); PinWindow.show(shot.image) },
            close: { CaptureOverlay.shared.end() }, dismissAfterShare: false)
        QuickBar.show(near: result.screenRect, actions: actions, tools: CaptureOverlay.shared.tools)
    }

    func capture() {
        guard !capturePending, !CaptureOverlay.shared.isActive else { return }
        QuickBar.dismiss()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 Hoot，然后重新启动应用。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        capturePending = true
        Task { [self] in
            defer { capturePending = false }
            do {
                let windows = ScreenCapture.windows()
                let ownRegions = AppSettings.shared.smartCapture ? CaptureRegionResolver.ownRegions() : []
                let shots = try await ScreenCapture.captureAll()
                CaptureOverlay.shared.onConfirm = { [weak self] in self?.pendingEdit?() }
                CaptureOverlay.shared.begin(shots: shots, windows: windows, ownRegions: ownRegions,
                                            onSelect: { [weak self] result in self?.showQuickBar(for: result) },
                                            onClear: { [weak self] in QuickBar.dismiss(); self?.pendingEdit = nil },
                                            completion: { [weak self] in QuickBar.dismiss(); self?.pendingEdit = nil })
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @discardableResult
    private func openEditor(image: CGImage, entry: HistoryEntry?, board: Bool = false) -> EditorWindowController {
        if let existing = editors.first {
            existing.model.load(doc: EditorWindowController.makeDocument(shot: image, entry: entry, board: board), entry: entry)
            existing.show()
            refreshPolicy()
            return existing
        }
        let controller = EditorWindowController(image: image, history: history, entry: entry, board: board)
        controller.onClose = { [weak self] c in self?.editors.removeAll { $0 === c }; self?.historyChanged(); self?.refreshPolicy() }
        editors.append(controller)
        refreshPolicy()
        controller.show()
        controller.model.documentChanged()
        return controller
    }
}
