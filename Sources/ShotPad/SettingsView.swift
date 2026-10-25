import AppKit
import SwiftUI
import ShotPadCore

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("截图") {
                Toggle("截图后自动复制到剪贴板", isOn: $settings.copyAfterCapture)
                HStack {
                    Text("编辑画板大小（像素）")
                    Spacer()
                    TextField("", value: $settings.boardWidth, format: .number.grouping(.never)).frame(width: 60).multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("", value: $settings.boardHeight, format: .number.grouping(.never)).frame(width: 60).multilineTextAlignment(.trailing)
                }
                Text("截图进入编辑时放在这块白色画板的左上角；截图比画板大时画板自动撑大。").font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 460, height: 520)
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
