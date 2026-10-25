import AppKit
import SwiftUI
import ShotPadCore

struct EditorInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var colorsExpanded = false
    @State private var strokeExpanded = false
    @State private var radiusExpanded = false
    @State private var drafts: [Dimension: String] = [:]
    @FocusState private var focusedDimension: Dimension?
    private let presets: [Color] = [EditorStyle.accent, Color(red: 1, green: 0.376, blue: 0.345), Color(red: 1, green: 0.741, blue: 0.18), Color(red: 0.208, green: 0.788, blue: 0.416), Color(red: 0.204, green: 0.212, blue: 0.243)]
    private var tool: Tool { model.tool }

    private enum Dimension: String, CaseIterable {
        case width = "W", height = "H", x = "X", y = "Y"
        var keyPath: WritableKeyPath<CGRect, CGFloat> {
            switch self { case .width: \.size.width; case .height: \.size.height; case .x: \.origin.x; case .y: \.origin.y }
        }
        var title: String {
            switch self { case .width: "宽度"; case .height: "高度"; case .x: "横坐标"; case .y: "纵坐标" }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.hasPatch ? "浮动块" : tool == .hand ? "图像" : tool.title)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.7))
                Spacer()
                Image(systemName: model.hasPatch ? "square.on.square.dashed" : tool == .hand ? "photo" : tool.symbol)
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 18).frame(height: 46)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.hasPatch { patchSection }
                    else if tool.usesColor || tool == .mosaic || tool == .blur { styleSection }
                    else if tool == .select || tool == .crop { selectionSection }
                    else { imageSection }
                    if model.selectionFrame != nil || [.rect, .ellipse, .line, .arrow, .text, .number].contains(tool) { geometrySection }
                    if !model.hasPatch && [.rect, .ellipse, .line, .arrow, .text, .number].contains(tool) { arrangementSection }
                    else if tool != .hand { hint(tool.hint) }
                }
            }.scrollIndicators(.hidden)
            Divider()
            Text(model.selectedAnnotation != nil ? "标注可随时调整" : "Hoot · 截图与标注")
                .font(.system(size: 10)).foregroundStyle(.tertiary).frame(height: EditorStyle.footerHeight)
        }.background(EditorStyle.panel)
            .onChange(of: focusedDimension) { old, next in if old != next, let old { commit(old) } }
            .onChange(of: model.selectedAnnotation?.id) { _, _ in drafts.removeAll() }
    }

    private var styleSection: some View {
        InspectorSection("样式") {
            if tool.usesColor {
                HStack(spacing: 7) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { index, color in
                        Button { model.colorValue = color } label: {
                            Circle().fill(color).frame(width: 19, height: 19).padding(3)
                                .overlay(Circle().strokeBorder(isCurrent(color) ? EditorStyle.accent : .clear, lineWidth: 1.8))
                        }.buttonStyle(.plain).accessibilityLabel(["蓝色", "红色", "黄色", "绿色", "石墨色"][index])
                    }
                    Button { colorsExpanded.toggle() } label: {
                        Circle().strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: 4)
                            .frame(width: 19, height: 19).padding(3)
                    }.buttonStyle(.plain).help("更多颜色、吸管与最近颜色").accessibilityLabel("更多颜色")
                        .popover(isPresented: $colorsExpanded) { colorPanel }
                }.padding(.bottom, 5)
            }
            if tool.usesWidth {
                property(tool == .mosaic || tool == .blur ? "强度" : "描边") {
                    Button { strokeExpanded.toggle() } label: {
                        InspectorWell {
                            HStack(spacing: 6) {
                                Capsule().fill(model.colorValue).frame(width: 37, height: min(5, max(1, model.lineWidth / 2)))
                                Text("\(Int(model.lineWidth)) px").foregroundStyle(.secondary)
                                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                            }.font(.system(size: 11))
                        }
                    }.buttonStyle(.plain).accessibilityLabel(tool == .mosaic || tool == .blur ? "调整强度" : "描边粗细")
                        .popover(isPresented: $strokeExpanded) { strokePanel }
                }
            }
            if tool == .rect || tool == .ellipse {
                property("填充") {
                    HStack(spacing: 5) {
                        fillButton(.none, name: "无填充")
                        fillButton(.translucent, name: "半透明填充")
                        fillButton(.solid, name: "实色填充")
                    }
                }
            }
            if tool == .text {
                property("字号") {
                    HStack(spacing: 5) {
                        Menu("\(Int(model.fontSize))") {
                            ForEach([12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96], id: \.self) { value in
                                Button("\(value)") { model.fontSize = CGFloat(value) }
                            }
                        }.fixedSize().help("常用字号")
                        Stepper("字号", value: $model.fontSize, in: 8...200, step: 2).labelsHidden()
                    }.controlSize(.small)
                }
            }
            if tool.usesColor {
                property("不透明度") { Text("\(Int((model.opacity * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit() }
                    .padding(.top, 3)
                InspectorSlider(value: $model.opacity, label: "不透明度").padding(.horizontal, -12.5).frame(height: 17).padding(.top, -5)
                if tool == .rect {
                    property("圆角") {
                        Button { radiusExpanded.toggle() } label: {
                            InspectorWell {
                                HStack {
                                    Text("\(Int(model.cornerRadius)) px")
                                    Spacer(minLength: 7)
                                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                                }.font(.system(size: 11)).frame(width: 64)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("圆角")
                            .popover(isPresented: $radiusExpanded) { radiusPanel }
                    }.padding(.top, 4)
                }
                property("阴影") { InspectorSwitch(isOn: $model.shadow, label: "阴影") }
            }
        }
    }

    private func fillButton(_ fill: Annotation.Fill, name: String) -> some View {
        Button { model.fill = fill } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill == .none ? Color.clear : EditorStyle.accent.opacity(fill == .translucent ? 0.22 : 0.45))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(fill == .none ? Color.secondary.opacity(0.65) : fill == .translucent ? EditorStyle.accent.opacity(0.35) : .clear, lineWidth: 1.3))
                .frame(width: 23, height: 12).frame(width: 45, height: 26)
                .background(model.fill == fill ? EditorStyle.well : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(EditorStyle.separator.opacity(0.55), lineWidth: 0.5))
                .shadow(color: .black.opacity(model.fill == fill ? 0.08 : 0), radius: 1.5, y: 1)
        }.buttonStyle(.plain).help(name).accessibilityLabel(name).accessibilityAddTraits(model.fill == fill ? .isSelected : [])
    }

    private var strokePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("\(tool == .mosaic || tool == .blur ? "强度" : "描边粗细")").fontWeight(.medium); Spacer(); Text("\(Int(model.lineWidth)) px").monospacedDigit() }
            Slider(value: numberBinding($model.lineWidth), in: 1...16).accessibilityLabel("线宽")
            HStack(spacing: 5) {
                ForEach([1, 2, 3, 4, 6, 8, 12, 16], id: \.self) { width in
                    Button("\(width)") { model.lineWidth = CGFloat(width) }.buttonStyle(.borderless)
                }
            }
        }.font(.system(size: 11)).padding(16).frame(width: 232)
    }
    private var radiusPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("圆角").fontWeight(.medium)
                Spacer()
                TextField("圆角像素", value: numberBinding($model.cornerRadius), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 55).multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }
            Slider(value: numberBinding($model.cornerRadius), in: 0...100).accessibilityLabel("圆角像素")
            HStack { ForEach([0, 4, 8, 12, 16, 24], id: \.self) { value in Button("\(value)") { model.cornerRadius = CGFloat(value) }.buttonStyle(.borderless) } }
        }.font(.system(size: 11)).padding(16).frame(width: 232)
    }
    private var colorPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("颜色").font(.system(size: 12, weight: .semibold))
            ColorPicker("自定义颜色", selection: $model.colorValue).font(.system(size: 12))
            Button { colorsExpanded = false; pickScreenColor() } label: { Label("吸取屏幕颜色", systemImage: "eyedropper").frame(maxWidth: .infinity) }.controlSize(.small)
            if !settings.recentColors.isEmpty {
                Divider()
                Text("最近使用").font(.system(size: 11)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                    ForEach(Array(settings.recentColors.enumerated()), id: \.offset) { _, color in
                        Button { model.colorValue = Color(nsColor: color.nsColor) } label: {
                            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.gray.opacity(0.2), lineWidth: 0.5))
                        }.buttonStyle(.plain).help("最近使用的颜色").accessibilityLabel("最近使用的颜色")
                    }
                }
            }
        }.padding(18).frame(width: 232)
    }

    private var geometrySection: some View {
        InspectorSection("尺寸与位置") {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { dimension(.width); dimension(.height) }
                GridRow { dimension(.x); dimension(.y) }
            }
            property("保持比例") {
                Button { model.aspectLocked.toggle() } label: {
                    Image(systemName: model.aspectLocked ? "lock" : "lock.open").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 23).contentShape(Rectangle())
                }.buttonStyle(.plain).help(model.aspectLocked ? "解除比例锁定" : "锁定宽高比例")
                    .accessibilityLabel("保持比例").accessibilityValue(model.aspectLocked ? "开启" : "关闭")
            }
        }
    }
    private func dimension(_ dimension: Dimension) -> some View {
        InspectorWell {
            HStack(spacing: 7) {
                Text(dimension.rawValue).foregroundStyle(.tertiary)
                TextField(dimension.title, text: Binding(get: {
                    drafts[dimension] ?? model.selectionFrame.map { Double($0[keyPath: dimension.keyPath]).formatted(.number.precision(.fractionLength(0))) } ?? "—"
                }, set: { drafts[dimension] = $0 }))
                .textFieldStyle(.plain).font(.system(size: 11)).monospacedDigit()
                .focused($focusedDimension, equals: dimension)
                .disabled(!model.canEditFrame).accessibilityLabel(dimension.title)
                .onSubmit { commit(dimension); focusedDimension = nil }
            }.font(.system(size: 11))
        }
    }
    private func commit(_ dimension: Dimension) {
        guard let draft = drafts.removeValue(forKey: dimension),
              let value = Double(draft.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)), value.isFinite else { return }
        let old = model.selectionFrame?[keyPath: dimension.keyPath]
        if old != CGFloat(value) { model.updateFrame(CGFloat(value), keyPath: dimension.keyPath) }
    }
    private var arrangementSection: some View {
        InspectorSection("排列") {
            arrangeButton("置于顶层", symbol: "arrow.up.to.line", toFront: true)
            arrangeButton("置于底层", symbol: "arrow.down.to.line", toFront: false)
            VStack(alignment: .leading, spacing: 4) {
                if tool == .rect || tool == .ellipse { Text("按住 Shift 绘制\(tool == .rect ? "正方形" : "正圆")") }
                Text("按 Delete 删除选中标注")
            }.font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(3).padding(.top, 5)
        }.overlay(alignment: .bottom) { EditorStyle.panel.frame(height: 1).padding(.horizontal, 18) }
    }
    private func arrangeButton(_ title: String, symbol: String, toFront: Bool) -> some View {
        Button { model.canvas?.reorderSelected(toFront: toFront) } label: {
            InspectorWell {
                HStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary); Text(title).font(.system(size: 11)) }
                    .frame(maxWidth: .infinity)
            }
        }.buttonStyle(.plain).disabled(model.selectedAnnotation == nil)
    }
    private var imageSection: some View {
        InspectorSection("图像") {
            property("宽度") { Text("\(Int(model.doc.size.width)) px").monospacedDigit() }
            property("高度") { Text("\(Int(model.doc.size.height)) px").monospacedDigit() }
            property("格式") { Text(model.currentEntry?.formatLabel ?? "PNG") }
            Button { model.pin() } label: { InspectorWell { Label("贴图到桌面", systemImage: "pin").font(.system(size: 11)).frame(maxWidth: .infinity) } }.buttonStyle(.plain)
        }
    }
    private var selectionSection: some View {
        InspectorSection(tool == .crop ? "裁剪" : "选区") {
            ColorPicker("选区框颜色", selection: $settings.selectionColor).font(.system(size: 11))
            if tool == .select {
                Button { model.canvas?.copySelection() } label: { InspectorWell { Label("复制选区", systemImage: "square.on.square").font(.system(size: 11)).frame(maxWidth: .infinity) } }
                    .buttonStyle(.plain).disabled(model.canvas?.selectionRect == nil)
            }
        }
    }
    private var patchSection: some View {
        InspectorSection("局部覆盖") {
            Text("拖动移动，拖手柄调整尺寸。确认后，浮动块会写入图像。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            Button("确认浮动块 ⏎") { model.canvas?.finishPatch() }.buttonStyle(.borderedProminent).controlSize(.small)
            Button("取消 Esc") { model.canvas?.cancelPatch() }.controlSize(.small)
        }
    }
    private func hint(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(4).padding(18) }
    private func property<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(minLength: 7); content() }.font(.system(size: 11)).frame(minHeight: 23)
    }
    private func numberBinding(_ source: Binding<CGFloat>) -> Binding<Double> {
        Binding(get: { Double(source.wrappedValue) }, set: { if $0.isFinite { source.wrappedValue = CGFloat(max(0, $0)) } })
    }
    private func isCurrent(_ color: Color) -> Bool {
        let a = RGBAWrapper(color).rgba, b = model.color.rgba
        return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) < 0.03
    }
    private func pickScreenColor() {
        NSColorSampler().show { color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            Task { @MainActor in
                model.colorValue = Color(.sRGB, red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), opacity: 1)
                settings.noteUsed(RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            content
        }.padding(.horizontal, 18).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().padding(.horizontal, 18) }
    }
}
