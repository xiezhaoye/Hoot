import SwiftUI
import ShotPadCore

struct ImageExportInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var templates: ImageExportTemplateStore
    @State private var preview: CGImage?
    @State private var naming = false
    @State private var renaming = false
    @State private var templateName = ""
    @State private var deleting = false

    init(model: EditorModel) {
        self.model = model; self.templates = model.exportTemplates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("图片背景").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            templateControls
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                        .accessibilityLabel("图片导出预览")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 22))
                        Text(model.canExportRegion ? "请选择背景图片" : "框选区域后预览图片").font(.system(size: 11))
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
                }
            }.frame(maxWidth: .infinity).frame(height: 130)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(spacing: 8) {
                Button { model.copyRegionImage() } label: {
                    Label("复制图片", systemImage: "square.on.square").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.borderedProminent)
                Button { model.saveRegionImage() } label: {
                    Label("保存图片", systemImage: "square.and.arrow.down").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.bordered)
            }.controlSize(.regular).disabled(!model.canExportRegion || (model.exportStyle.background == .image && model.exportBackground == nil))
            Picker("背景", selection: Binding(get: { model.exportStyle.background }, set: { value in
                if value == .image && model.exportBackground == nil { model.chooseExportBackground() }
                else { model.exportStyle.background = value }
            })) {
                Text("无背景").tag(ImageExportStyle.Background.none)
                Text("纯色").tag(ImageExportStyle.Background.solid)
                Text("渐变").tag(ImageExportStyle.Background.gradient)
                Text("图片").tag(ImageExportStyle.Background.image)
            }.controlSize(.small)
            if model.exportStyle.background == .solid || model.exportStyle.background == .gradient {
                ColorPicker(model.exportStyle.background == .gradient ? "起始颜色" : "背景颜色", selection: color(\.color), supportsOpacity: false)
                if model.exportStyle.background == .gradient {
                    ColorPicker("结束颜色", selection: color(\.gradientEnd), supportsOpacity: false)
                }
            }
            if model.exportStyle.background == .image {
                Button("更换背景图片…") { model.chooseExportBackground() }.controlSize(.small)
                Text("等比例铺满，居中裁切").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if model.exportStyle.background != .none {
                slider("背景留白", value: \ImageExportStyle.padding, range: 0...256)
                slider("内容圆角", value: \ImageExportStyle.cornerRadius, range: 0...64)
                HStack {
                    Text("内容阴影").foregroundStyle(.secondary)
                    Spacer()
                    InspectorSwitch(isOn: $model.exportStyle.shadow, label: "内容阴影")
                }
            }
        }.font(.system(size: 11))
            .onAppear(perform: updatePreview)
            .onChange(of: model.revision) { _, _ in updatePreview() }
            .onChange(of: model.exportStyle) { _, _ in updatePreview() }
            .onChange(of: model.exportBackground) { _, _ in updatePreview() }
            .onChange(of: templates.library) { _, library in
                if !library.templates.contains(where: { $0.id == model.selectedExportTemplateID }) { model.selectExportTemplate(library.defaultID) }
            }
            .alert(renaming ? "重命名模板" : "另存为模板", isPresented: $naming) {
                TextField("模板名称", text: $templateName)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if renaming { model.renameExportTemplate(templateName) }
                    else { model.saveExportTemplate(name: templateName) }
                }.disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("删除模板「\(model.selectedExportTemplate?.name ?? "")」？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { model.deleteExportTemplate() }
            } message: { Text("会切换到其他模板，删除的模板可在废纸篓中找回。") }
    }

    private var templateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("模板", selection: Binding(get: { model.selectedExportTemplateID }, set: { model.selectExportTemplate($0) })) {
                ForEach(templates.library.templates) { template in
                    Text(template.name + (template.id == templates.library.defaultID ? " · 默认" : "")).tag(template.id)
                }
            }.controlSize(.small)
            HStack(spacing: 8) {
                Button("保存修改") { model.saveExportTemplate() }.disabled(!model.exportTemplateModified)
                Menu("模板操作") {
                    Button("另存为模板…") { renaming = false; templateName = (model.selectedExportTemplate?.name ?? "模板") + " 副本"; naming = true }
                    Button("设为默认") { model.saveExportTemplate(makeDefault: true) }
                        .disabled(model.selectedExportTemplateID == templates.library.defaultID && !model.exportTemplateModified)
                    Button("重命名…") { renaming = true; templateName = model.selectedExportTemplate?.name ?? ""; naming = true }
                    Divider()
                    Button("删除模板…", role: .destructive) { deleting = true }.disabled(templates.library.templates.count <= 1)
                }
            }.controlSize(.small)
            if model.exportTemplateModified { Text("已修改，保存后更新模板").foregroundStyle(.secondary) }
            Text("浮层分享：\(templates.library.defaultTemplate.name)").foregroundStyle(.tertiary).lineLimit(2)
        }.font(.system(size: 10))
    }

    private func updatePreview() { preview = model.regionExportImage(preview: true) }
    private func color(_ path: WritableKeyPath<ImageExportStyle, RGBA>) -> Binding<Color> {
        Binding(get: { Color(nsColor: model.exportStyle[keyPath: path].nsColor) }, set: { model.exportStyle[keyPath: path] = RGBAWrapper($0).rgba })
    }
    private func slider(_ title: String, value: WritableKeyPath<ImageExportStyle, CGFloat>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                TextField(title, value: Binding(get: { Int(model.exportStyle[keyPath: value]) }, set: {
                    model.exportStyle[keyPath: value] = CGFloat(max(range.lowerBound, min(range.upperBound, Double($0))))
                }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 45).multilineTextAlignment(.trailing).monospacedDigit()
                Text("px").foregroundStyle(.secondary)
            }
            InspectorSlider(value: Binding(get: { Double(model.exportStyle[keyPath: value]) }, set: { model.exportStyle[keyPath: value] = CGFloat($0.rounded()) }), range: range, label: title)
        }
    }
}
