import AppKit
import SwiftUI
import Translation
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
    (.text, "textformat", "文字"), (.number, "1.circle", "序号"), (.crop, "crop", "裁剪（回车确认）"),
]

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                CanvasRepresentable(model: model)
                Divider()
                actionBar
            }
            Divider()
            historyPane
        }
        .translationTask(model.translationConfig) { session in
            await model.performTranslation(session)
        }
        .sheet(item: Binding(get: { model.ocrText.map(OCRText.init) }, set: { model.ocrText = $0?.text })) { item in
            OCRSheet(text: item.text) { model.ocrText = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(toolIcons, id: \.0) { tool, icon, help in
                Button { model.tool = tool; model.canvas?.window?.invalidateCursorRects(for: model.canvas!) } label: {
                    Image(systemName: icon).frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(model.tool == tool ? .accentColor : nil)
                .help(help)
            }
            Divider().frame(height: 22)
            ColorPicker("", selection: $model.colorValue).labelsHidden()
            Slider(value: $model.lineWidth, in: 1...16).frame(width: 80).help("线宽 / 马赛克强度")
            Stepper("字号 \(Int(model.fontSize))", value: $model.fontSize, in: 10...120, step: 2).font(.caption)
            Spacer()
        }
        .padding(8)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { model.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!(model.revision >= 0 && model.doc.canUndo)).help("撤销 ⌘Z")
            Button { model.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!(model.revision >= 0 && model.doc.canRedo)).help("重做 ⇧⌘Z")
            Divider().frame(height: 18)
            Button("复制") { model.copyAll() }
            Button("保存…") { model.saveAs() }
            Button("贴图") { model.pin() }
            Divider().frame(height: 18)
            Button("识别文字") { model.runOCR() }.disabled(model.busy)
            Button("翻译") { model.translate() }.disabled(model.busy)
            Picker("", selection: Binding(get: { model.targetChinese.map { $0 ? 1 : 2 } ?? 0 },
                                          set: { model.targetChinese = $0 == 0 ? nil : $0 == 1 })) {
                Text("自动方向").tag(0); Text("译成中文").tag(1); Text("译成英文").tag(2)
            }.labelsHidden().frame(width: 100)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("历史截图").font(.headline).padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.entries) { entry in
                        HistoryThumb(model: model, entry: entry)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 170)
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

private struct OCRText: Identifiable { let text: String; var id: String { text } }

private struct OCRSheet: View {
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别结果").font(.headline)
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: 440, height: 260)
                .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("复制文字") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }
}
