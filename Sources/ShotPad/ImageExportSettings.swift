import AppKit
import UniformTypeIdentifiers
import ShotPadCore

extension EditorModel {
    @discardableResult func rememberExportConfiguration() -> Bool {
        do {
            try exportTemplates.saveWorkingConfiguration(style: exportStyle, templateID: selectedExportTemplateID, backgroundPNG: exportBackgroundPNG)
            return true
        } catch { status = "图片设置保存失败：\(error.localizedDescription)"; return false }
    }
    var selectedExportTemplate: ImageExportTemplate? {
        exportTemplates.library.templates.first { $0.id == selectedExportTemplateID }
    }
    var exportTemplateModified: Bool {
        guard let template = selectedExportTemplate else { return true }
        return template.style != exportStyle || template.backgroundPNG != exportBackgroundPNG
    }
    func selectExportTemplate(_ id: UUID) {
        do {
            let template = try exportTemplates.select(id)
            selectedExportTemplateID = id
            exportBackgroundPNG = template.backgroundPNG
            exportBackground = ImageExportTemplateStore.image(from: template.backgroundPNG)
            exportStyle = template.style
        } catch { status = "模板切换失败：\(error.localizedDescription)" }
    }
    @discardableResult func saveExportTemplate(name: String? = nil, makeDefault: Bool = false) -> Bool {
        do {
            let template = try exportTemplates.save(id: name == nil ? selectedExportTemplateID : nil,
                name: name ?? selectedExportTemplate?.name ?? "新模板", style: exportStyle,
                backgroundPNG: exportBackgroundPNG, makeDefault: makeDefault)
            selectedExportTemplateID = template.id
            guard rememberExportConfiguration() else { return false }
            status = makeDefault ? "已设为默认模板，浮层分享将使用「\(template.name)」" : "已保存模板「\(template.name)」"
            return true
        } catch { status = "模板保存失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult func renameExportTemplate(_ name: String) -> Bool {
        do { try exportTemplates.rename(selectedExportTemplateID, to: name); return rememberExportConfiguration() }
        catch { status = "重命名失败：\(error.localizedDescription)"; return false }
    }
    func deleteExportTemplate() {
        do {
            try exportTemplates.remove(selectedExportTemplateID)
            selectExportTemplate(exportTemplates.library.selectedID)
            status = "模板已移到废纸篓"
        } catch { status = "删除模板失败：\(error.localizedDescription)" }
    }
    var exportRegion: CGRect? {
        guard tool == .select || tool == .crop else { return nil }
        return canvas?.activeSelectionRect ?? (tool == .select ? doc.patch?.rect : nil)
    }
    var canExportRegion: Bool { exportRegion.map { $0.width >= 1 && $0.height >= 1 } == true }

    func regionExportImage(preview: Bool = false) -> CGImage? {
        guard let rect = exportRegion, let image = doc.image(in: rect) else { return nil }
        let padding = exportStyle.background == .none ? 0 : max(0, min(256, exportStyle.padding)) * 2
        let longest = max(CGFloat(image.width), CGFloat(image.height)) + padding
        let scale = preview ? min(1, 512 / longest) : 1
        return ImageExportRenderer.render(image, style: exportStyle, backgroundImage: exportBackground, scale: scale)
    }

    func copyRegionImage() {
        guard let image = regionExportImage() else { status = "请先框选区域；使用图片背景时，请先选择背景图片"; return }
        Clipboard.write(image)
        status = "已复制图片 \(image.width)×\(image.height)"
    }

    /// Exporting a decorated region never crops, fixes, or changes the source document.
    @discardableResult func saveRegionImage(to url: URL) -> Bool {
        guard let image = regionExportImage(), let png = image.pngData else { status = "无法生成图片，请检查选区和背景"; return false }
        do {
            try png.write(to: url, options: .atomic)
            status = "已保存图片 \(url.lastPathComponent)"
            return true
        } catch { status = "保存失败：\(error.localizedDescription)"; return false }
    }

    func saveRegionImage() {
        guard canExportRegion else { status = "请先框选要保存的区域"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Hoot 图片.png"
        if panel.runModal() == .OK, let url = panel.url { saveRegionImage(to: url) }
    }

    func chooseExportBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = ImageLoader.loadFull(url), let png = image.pngData else { status = "无法读取背景图片，请选择其他图片"; return }
        do {
            try exportTemplates.saveWorkingBackground(png)
            exportBackgroundPNG = png; exportBackground = image; exportStyle.background = .image
        } catch { status = "背景保存失败：\(error.localizedDescription)" }
    }
}

@MainActor
enum CaptureImageSharing {
    /// Finish the capture first; the formatted PNG must be the final pasteboard write.
    static func copy(_ image: CGImage, templates: ImageExportTemplateStore? = nil, beforeCopy: () -> Void = {}) -> Bool {
        guard let rendered = (templates ?? .shared).renderDefault(image) else { return false }
        beforeCopy()
        Clipboard.write(rendered)
        return true
    }
}
