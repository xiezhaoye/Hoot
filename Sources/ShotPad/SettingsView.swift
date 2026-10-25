import AppKit
import SwiftUI
import ShotPadCore

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testResult = ""
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
        Form {
            Section("截图") {
                HStack {
                    Text("截图快捷键")
                    Spacer()
                    ShortcutRecorder(settings: settings)
                }
                Picker("保存格式", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("截图后自动复制到剪贴板", isOn: $settings.copyAfterCapture)
                HStack {
                    Text("编辑画板大小（像素）")
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
                Text("宽 × 高，单位是像素（Retina 屏上 1920 像素显示为 960 点宽）。截图进入编辑时放在这块白色画板的左上角；比画板大时画板自动撑大。预设里最后一项是 A4 @300dpi。").font(.caption).foregroundStyle(.secondary)
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
                Picker("历史栏位置", selection: $settings.historySide) {
                    Text("左侧").tag(AppSettings.HistorySide.left)
                    Text("右侧").tag(AppSettings.HistorySide.right)
                }.pickerStyle(.segmented)
                ColorPicker("标注颜色（画笔、箭头、文字等）", selection: $settings.annotationColor)
                ColorPicker("选区 / 裁剪框颜色", selection: $settings.selectionColor)
            }
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
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}


/// Click, then press the new key combination (at least one of ⌃ ⌥ ⇧ ⌘); Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "请按下新的快捷键…" : settings.captureShortcutText) { toggle() }
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
            settings.captureKeyLabel = Self.label(for: e)
            settings.captureKeyCode = Int(e.keyCode)
            settings.captureModifiers = mods
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
