import AppKit
import SwiftUI
import ShotPadCore
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testResult = ""
    @ObservedObject private var updater = UpdateManager.shared
    @State private var category = "通用"
    @State private var testing = false
    @State private var historyPath = Settings.historyDirectory.path
    @State private var directoryNote = ""

    /// Copies the existing screenshots to the chosen folder; Hoot uses it from the next launch.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let old = Settings.historyDirectory
        guard url.standardizedFileURL != old.standardizedFileURL else { return }
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
            let dest = url.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: f, to: dest) }
        }
        Settings.historyDirectory = url
        historyPath = url.path
        directoryNote = "已复制现有截图，重启 Hoot 后生效"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([("通用", "slider.horizontal.3"), ("快捷键", "keyboard"), ("识字与翻译", "translate"), ("关于与更新", "info.circle")], id: \.0) { title, icon in
                    Button { category = title } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).resizable().scaledToFit().frame(width: 18, height: 18).frame(width: 22, height: 22)
                            Text(title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        }.foregroundStyle(Color.primary.opacity(0.78))
                            .padding(.horizontal, 10).frame(height: 42).frame(maxWidth: .infinity, alignment: .leading)
                            .background(category == title ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).focusEffectDisabled()
                }
                Spacer()
            }.padding(14).frame(width: 158).background(.bar)
            Divider()
            Form {
            if category == "通用" {
            Section("截图") {
                Picker("保存格式", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("截图后自动复制到剪贴板", isOn: $settings.copyAfterCapture)
                Toggle("截图后弹出主窗口", isOn: $settings.openMainAfterCapture)
                Text("关闭时，复制、识别、翻译、钉住等操作不打开主窗口，也不留下历史文件；只有点「编辑」或按回车进入主窗口的截图才会保存到历史。").font(.caption).foregroundStyle(.secondary)
                Toggle("智能识别窗口内部模块", isOn: $settings.smartCapture)
                Text("悬停选择控件、面板或窗口，滚轮 / Tab 切换范围；随时可拖动框选。未授权时使用本机图像识别，授权辅助功能后可更准确地识别其他 App 的控件。").font(.caption).foregroundStyle(.secondary)
                Button("授权辅助功能…") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }.disabled(!settings.smartCapture)
                Toggle("截图圆角", isOn: $settings.roundedCapture)
                if settings.roundedCapture {
                    HStack {
                        Text("圆角半径（像素）").lineLimit(1).fixedSize()
                        Spacer()
                        TextField("", value: $settings.captureRadius, format: .number.precision(.fractionLength(0)))
                            .frame(width: 55).multilineTextAlignment(.trailing)
                        Stepper("圆角半径", value: $settings.captureRadius, in: 0...200, step: 2).labelsHidden()
                        Menu("预设") { ForEach([0, 4, 8, 12, 16, 24, 32, 48], id: \.self) { radius in Button("\(radius) px") { settings.captureRadius = Double(radius) } } }.fixedSize()
                    }
                    Text("0 为直角；圆角区域透明，实际半径不超过截图短边的一半。PNG 可保留透明圆角，JPG 等格式会使用白底。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("编辑画板大小（像素）").lineLimit(1).fixedSize()
                    Spacer()
                    TextField("", value: $settings.boardWidth, format: .number.grouping(.never)).frame(width: 60).multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("", value: $settings.boardHeight, format: .number.grouping(.never)).frame(width: 60).multilineTextAlignment(.trailing)
                    Menu("预设") {
                        ForEach([(1920, 1080), (2560, 1440), (3840, 2160), (2480, 3508)], id: \.0) { w, h in
                            Button("\(w) × \(h)") { settings.boardWidth = w; settings.boardHeight = h }
                        }
                    }.fixedSize()
                }
                Text("宽 × 高，单位是像素（Retina 屏上 1920 像素显示为 960 点宽）。截图进入编辑时居中放在这块白色画板上，可整体移动；比画板大时画板自动撑大。预设里最后一项是 A4 @300dpi。").font(.caption).foregroundStyle(.secondary)
            }
            Section("存储与格式") {
                HStack {
                    Text("截图保存目录")
                    Spacer()
                    Text(historyPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("更改…") { chooseDirectory() }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([Settings.historyDirectory]) }
                    if !directoryNote.isEmpty { Text(directoryNote).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("界面") {
                Toggle("始终在 Dock 显示", isOn: $settings.alwaysInDock)
                Toggle("首次打开时弹出主窗口", isOn: $settings.openMainOnLaunch)
                Picker("历史栏位置", selection: $settings.historySide) {
                    Text("左侧").tag(AppSettings.HistorySide.left)
                    Text("右侧").tag(AppSettings.HistorySide.right)
                }.pickerStyle(.segmented)
                ColorPicker("标注颜色（画笔、箭头、文字等）", selection: $settings.annotationColor)
                ColorPicker("选区 / 裁剪框颜色", selection: $settings.selectionColor)
            }
            }
            if category == "快捷键" {
            Section("快捷键") {
                HStack {
                    Text("截图")
                    Spacer()
                    ShortcutRecorder(text: settings.captureShortcutText) { key, mods, label in
                        settings.captureKeyLabel = label; settings.captureKeyCode = key; settings.captureModifiers = mods
                    }
                }
                HStack {
                    Text("保存")
                    Spacer()
                    ShortcutRecorder(text: settings.saveShortcutText) { key, mods, label in
                        settings.saveKeyLabel = label; settings.saveKeyCode = key; settings.saveModifiers = mods
                    }
                }
                Text("点击后按下新的组合键（至少包含 ⌃ ⌥ ⇧ ⌘ 之一），Esc 取消。保存会把当前画板导出为图片文件；所有内容在关闭软件时都会自动保存到历史。").font(.caption).foregroundStyle(.secondary)
            }
            }
            if category == "识字与翻译" {
            Section("本地识字") { Text("使用 macOS Vision 在本机识别文字，无需上传图片。").foregroundStyle(.secondary) }
            Section("大模型翻译（OpenAI 兼容接口）") {
                TextField("Base URL", text: $settings.baseURL, prompt: Text("https://api.openai.com/v1"))
                SecureField("API Key", text: $settings.apiKey)
                TextField("模型名", text: $settings.model, prompt: Text("gpt-4o-mini"))
                HStack {
                    Button("测试连接") { test() }.disabled(settings.llm == nil || testing)
                    if testing { ProgressView().controlSize(.small) }
                    Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("三项都填写才会启用，翻译时优先使用；失败或未配置时回退到系统本地翻译。Key 保存在系统钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            if category == "关于与更新" {
                Section("Hoot") {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage).renderingMode(.template).resizable().foregroundStyle(.primary).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Hoot").font(.title2.bold())
                            Text("版本 \(UpdateManager.version)（\(UpdateManager.build)）").foregroundStyle(.secondary)
                            Text("截图 · 浏览 · 编辑").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Link("GitHub · 源码与反馈", destination: URL(string: "https://github.com/xiezhaoye/Hoot")!)
                    Link("Hoot 主页", destination: URL(string: "https://hoot.xiezhaoye.site/")!)
                    Text("© 2026 xiezhaoye · MIT License").font(.caption).foregroundStyle(.secondary)
                }
                Section("在线更新") {
                    Toggle("自动检查更新", isOn: $updater.automaticallyCheck)
                    Text("自动检查每日一次。安装前会提示，重启后恢复画板、可编辑对象和撤销记录。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("检查更新") { Task { await updater.check() } }.disabled(updater.busy)
                        if updater.busy { ProgressView().controlSize(.small) }
                        if updater.available != nil { Button("安装并重启") { Task { await updater.install() } }.disabled(updater.busy).buttonStyle(.borderedProminent) }
                    }
                    if !updater.message.isEmpty { Text(updater.message).font(.caption).textSelection(.enabled) }
                    if let notes = updater.available?.body { Text(notes).font(.caption).textSelection(.enabled) }
                }
            }
            }.formStyle(.grouped).frame(maxWidth: .infinity)
        }.frame(width: 740, height: 650)
    }

    private func test() {
        guard let cfg = settings.llm else { return }
        testing = true; testResult = ""
        Task {
            do {
                let out = try await LLMTranslator.translate(lines: ["Hello"], toChinese: true, config: cfg)
                testResult = "成功：Hello → \(out.first ?? "")"
            } catch { testResult = "失败：\(error.localizedDescription)" }
            testing = false
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static var isVisible: Bool { window?.isVisible ?? false }

    static func show() {
        let editor = NSApp.windows.first { $0.isKeyWindow && $0.title == "Hoot" }
            ?? NSApp.windows.first { $0.isMainWindow && $0.title == "Hoot" }
            ?? NSApp.windows.first { $0.isVisible && $0.title == "Hoot" }
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Hoot 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                // the window is still "visible" while willClose is delivered
                DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.refreshPolicy() }
            }
            window = w
        }
        if let w = window {
            let screen = editor?.screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            let area = editor?.frame ?? screen?.visibleFrame ?? w.frame
            let visible = screen?.visibleFrame ?? area
            let x = min(max(area.midX - w.frame.width / 2, visible.minX), max(visible.minX, visible.maxX - w.frame.width))
            let y = min(max(area.midY - w.frame.height / 2, visible.minY), max(visible.minY, visible.maxY - w.frame.height))
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}


/// Click, then press the new key combination (at least one of ⌃ ⌥ ⇧ ⌘); Esc cancels.
struct ShortcutRecorder: View {
    let text: String
    let onRecord: (_ keyCode: Int, _ modifiers: Int, _ label: String) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "请按下新的快捷键…" : text) { toggle() }
            .frame(minWidth: 130)
            .onDisappear { stop() }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods = 0
            if f.contains(.control) { mods |= 4096 }
            if f.contains(.option) { mods |= 2048 }
            if f.contains(.shift) { mods |= 512 }
            if f.contains(.command) { mods |= 256 }
            guard mods != 0 else { NSSound.beep(); return nil }
            onRecord(Int(e.keyCode), mods, Self.label(for: e))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func label(for e: NSEvent) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return special[e.keyCode] ?? (e.charactersIgnoringModifiers?.uppercased() ?? "?")
    }
}
