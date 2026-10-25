import AppKit
import SwiftUI
import ShotPadCore

struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = CanvasView(frame: .zero)
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        model.canvas = canvas
        DispatchQueue.main.async { canvas.attach(model) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? CanvasView)?.window?.invalidateCursorRects(for: scroll.documentView!)
    }
}

private let toolIcons: [(Tool, String, String)] = [
    (.select, "rectangle.dashed", "选区 / 复制粘贴 / 移动覆盖"),
    (.rect, "rectangle", "矩形"), (.ellipse, "circle", "圆圈"), (.line, "line.diagonal", "直线"),
    (.arrow, "arrow.up.right", "箭头"), (.pen, "pencil.tip", "画笔"), (.highlighter, "highlighter", "荧光笔"),
    (.mosaic, "squareshape.split.3x3", "马赛克"), (.blur, "drop", "模糊"),
    (.text, "text:A", "文字"), (.number, "1.circle", "序号"), (.crop, "crop", "裁剪（回车确认）"),
]

enum SideTab: String, CaseIterable { case shots = "截图", browse = "浏览" }

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var browse = BrowseModel()
    @State private var tab: SideTab = .shots

    var body: some View {
        HStack(spacing: 0) {
            if settings.historySide == .left { historyPane; Divider() }
            ZStack {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    optionsBar
                    Divider()
                    CanvasRepresentable(model: model)
                }
                .opacity(tab == .shots ? 1 : 0).allowsHitTesting(tab == .shots)
                if tab == .browse {
                    BrowseDetail(model: browse) { image in editFromBrowse(image) }
                }
            }
            if settings.historySide == .right { Divider(); historyPane }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(toolIcons, id: \.0) { tool, icon, help in
                let on = model.tool == tool
                Button {
                    model.canvas?.finishTextEditing()
                    model.tool = on ? .hand : tool          // pressing the active tool again puts it down
                    model.canvas?.window?.invalidateCursorRects(for: model.canvas!)
                } label: {
                    Group {
                        if icon.hasPrefix("text:") {
                            Text(String(icon.dropFirst(5))).font(.system(size: 15, weight: .bold, design: .serif))
                        } else {
                            Image(systemName: icon)
                        }
                    }
                    .frame(width: 26, height: 22)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.clear))
                }
                .buttonStyle(.bordered)
                .help(help)
            }
            Spacer(minLength: 12)
            if model.hasPatch {
                Button("确认浮动块") { model.canvas?.finishPatch() }.buttonStyle(.borderedProminent)
                Button("取消") { model.canvas?.cancelPatch() }
                Divider().frame(height: 18)
            }
            Button { model.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!(model.revision >= 0 && model.doc.canUndo)).help("撤销 ⌘Z")
            Button { model.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!(model.revision >= 0 && model.doc.canRedo)).help("重做 ⇧⌘Z")
            Divider().frame(height: 18)
            Button("识别文字") { model.runOCR() }
            Button("翻译") { model.translate() }
            Picker("", selection: Binding(get: { model.targetChinese.map { $0 ? 1 : 2 } ?? 0 },
                                          set: { model.targetChinese = $0 == 0 ? nil : $0 == 1 })) {
                Text("自动方向").tag(0); Text("译成中文").tag(1); Text("译成英文").tag(2)
            }.labelsHidden().frame(width: 100)
        }
        .padding(8)
    }

    /// Second row: settings for the active tool (and for the selected annotation); the status text sits on the right.
    private var optionsBar: some View {
        HStack(spacing: 10) {
            switch model.tool {
            case .rect, .ellipse, .line, .arrow, .pen, .highlighter, .number:
                colorControls
                HStack { Text("粗细").font(.caption); Slider(value: $model.lineWidth, in: 1...16).frame(width: 110) }
            case .mosaic, .blur:
                HStack { Text("强度").font(.caption); Slider(value: $model.lineWidth, in: 1...16).frame(width: 110) }
            case .text:
                colorControls
                Menu("字号 \(Int(model.fontSize))") {
                    ForEach([12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96], id: \.self) { n in
                        Button("\(n)") { model.fontSize = CGFloat(n) }
                    }
                }.fixedSize()
                Stepper("", value: $model.fontSize, in: 8...200, step: 2).labelsHidden()
            case .select, .crop:
                ColorPicker("选区框颜色", selection: $settings.selectionColor)
            case .hand:
                Text("未选工具：拖动画面可平移，捏合可缩放").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            zoomMenu
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var zoomMenu: some View {
        Menu("\(model.zoomPercent)%") {
            ForEach([25, 50, 100, 200, 400, 800], id: \.self) { p in Button("\(p)%") { model.canvas?.setZoomPercent(p) } }
            Divider()
            Button("适应窗口") { model.canvas?.zoomToFit() }
        }
        .fixedSize().help("缩放（触控板捏合；⌘+ ⌘- ⌘0）")
    }

    /// Colour well, eyedropper and the ten most recently used colours.
    private var colorControls: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: $model.colorValue).labelsHidden()
            Button { pickScreenColor() } label: { Image(systemName: "eyedropper") }.help("吸取屏幕上的颜色")
            HStack(spacing: 3) {
                ForEach(Array(settings.recentColors.enumerated()), id: \.offset) { _, c in
                    Button { model.colorValue = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) } label: {
                        Circle().fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.gray.opacity(0.5), lineWidth: 0.5))
                    }.buttonStyle(.plain).help("最近使用的颜色")
                }
            }
        }
    }

    private func pickScreenColor() {
        NSColorSampler().show { picked in
            guard let picked, let c = picked.usingColorSpace(.sRGB) else { return }
            model.colorValue = Color(.sRGB, red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), opacity: 1)
            AppSettings.shared.noteUsed(RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
        }
    }

    /// Sends a browsed picture to the editor as a new 截图 entry; the original file is never touched.
    private func editFromBrowse(_ image: CGImage) {
        guard let entry = model.history.add(image) else { return }
        model.entries = model.history.entries
        model.open(entry)
        tab = .shots
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SideTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            switch tab {
            case .shots:
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.entries) { entry in
                            HistoryThumb(model: model, entry: entry)
                        }
                    }
                    .padding(8)
                }
            case .browse:
                BrowseSidebar(model: browse)
            }
        }
        .frame(width: 200)
    }
}

private struct HistoryThumb: View {
    @ObservedObject var model: EditorModel
    let entry: HistoryEntry

    var body: some View {
        let thumb = model.history.thumbnail(for: entry.id)
        VStack(spacing: 2) {
            if let thumb {
                Image(decorative: thumb, scale: 2).resizable().scaledToFit().frame(maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(entry.id == model.currentID ? Color.accentColor : .gray.opacity(0.3), lineWidth: entry.id == model.currentID ? 2 : 1))
            }
            Text(entry.date, format: .dateTime.month().day().hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
        }
        .onTapGesture { model.open(entry) }
        .contextMenu { Button("删除", role: .destructive) { model.deleteEntry(entry) } }
    }
}
