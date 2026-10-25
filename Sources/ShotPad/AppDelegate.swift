import AppKit
import SwiftUI
import ShotPadCore

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: EditorModel
    var onClose: ((EditorWindowController) -> Void)?

    init(image shot: CGImage, history: HistoryStore, entry: HistoryEntry?, board: Bool = false) {
        let image = board ? Board.make(placing: shot, size: AppSettings.shared.boardSize) : shot
        model = EditorModel(image: image, history: history, entry: entry)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let w = min(CGFloat(image.width) / scale + 170, visible.width * 0.9)
        let h = min(CGFloat(image.height) / scale + 110, visible.height * 0.9)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: max(w, 900), height: max(h, 520)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Hoot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.canvas?.finishPatch()
        model.persistCurrent()
        onClose?(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var editors: [EditorWindowController] = []
    private let history = HistoryStore(directory: Settings.historyDirectory, limit: Settings.historyLimit)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Hoot")
        statusItem.menu = makeMenu()
        HotKey.register(keyCode: 0, modifiers: 4096 | 2048, id: 1) { [weak self] in self?.capture() }   // ⌃⌥A
        HotKey.register(keyCode: 35, modifiers: 4096 | 2048, id: 2) { [weak self] in self?.pinClipboard() } // ⌃⌥P
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        TextTools.warmUp()
        NSApp.mainMenu = makeMainMenu()
        refreshPolicy()
        openMain()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click with no window open: bring up the latest shot, or the settings if there is none.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMain() }
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
        app.addItem(item("截图", #selector(captureAction)))
        let prefs = item("设置…", #selector(openSettings)); prefs.keyEquivalent = ","
        app.addItem(prefs)
        app.addItem(.separator())
        let quit = item("退出 Hoot", #selector(NSApplication.terminate(_:)), target: NSApp); quit.keyEquivalent = "q"
        app.addItem(quit)
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        for (title, sel, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
                                  ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: sel, keyEquivalent: key)
        }
        editItem.submenu = edit
        return main
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("截图  ⌃⌥A", #selector(captureAction)))
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

    private func showQuickBar(for result: CaptureResult) {
        let image = result.image
        let entry = history.add(image)
        historyChanged()
        if AppSettings.shared.copyAfterCapture { Clipboard.write(image) }
        let actions = QuickActions(
            copyText: { report in
                Task { @MainActor in
                    do {
                        let text = try await TextTools.extractText(image)
                        if text.isEmpty { report("没有识别到文字"); return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        report("已复制 \(text.count) 字")
                    } catch { report("识别失败") }
                }
            },
            translate: { TextTools.showTranslation(image, toChinese: nil) { _ in } },
            edit: { [weak self] in QuickBar.dismiss(); self?.openEditor(image: image, entry: entry, board: true) },
            copyImage: { Clipboard.write(image) },
            pin: { PinWindow.show(image) },
            close: { QuickBar.dismiss() })
        QuickBar.show(near: result.screenRect, image: image, actions: actions)
    }

    func capture() {
        guard !CaptureOverlay.shared.isActive else { return }
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
        Task {
            do {
                let shots = try await ScreenCapture.captureAll()
                let windows = ScreenCapture.windows()
                CaptureOverlay.shared.begin(shots: shots, windows: windows) { [weak self] result in
                    guard let self, let result else { return }
                    self.showQuickBar(for: result)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func openEditor(image: CGImage, entry: HistoryEntry?, board: Bool = false) {
        let controller = EditorWindowController(image: image, history: history, entry: entry, board: board)
        controller.onClose = { [weak self] c in self?.editors.removeAll { $0 === c }; self?.historyChanged(); self?.refreshPolicy() }
        editors.append(controller)
        refreshPolicy()
        controller.show()
    }
}
