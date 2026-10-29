import AppKit
import ImageIO
import ShotPadCore

/// Saved templates are shared by editor windows and the capture overlay.
@MainActor
final class ImageExportTemplateStore: ObservableObject {
    static let shared = ImageExportTemplateStore()
    @Published private(set) var library: ImageExportTemplateLibrary
    private let defaults: UserDefaults
    private let url: URL
    private let workingBackgroundURL: URL
    private let trashTemplate: (URL) throws -> Void
    private let styleKey = "imageExportStyle"
    private let backgroundKey = "imageExportWorkingBackgroundPresent"
    private let workingIDKey = "imageExportWorkingTemplateID"
    private var backgroundCache: Data?

    init(defaults: UserDefaults = .standard, directory: URL? = nil, trashTemplate: ((URL) throws -> Void)? = nil) {
        self.defaults = defaults
        self.trashTemplate = trashTemplate ?? { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShotPad")
        url = directory.appendingPathComponent("ImageTemplates.plist")
        workingBackgroundURL = directory.appendingPathComponent("ExportBackground.png")
        let style = defaults.data(forKey: styleKey).flatMap { try? JSONDecoder().decode(ImageExportStyle.self, from: $0) } ?? ImageExportStyle()
        let background = defaults.object(forKey: backgroundKey) as? Bool == false ? nil : try? Data(contentsOf: workingBackgroundURL)
        backgroundCache = background
        if let data = try? Data(contentsOf: url), let saved = try? PropertyListDecoder().decode(ImageExportTemplateLibrary.self, from: data), saved.isValid {
            library = saved
        } else {
            library = ImageExportTemplateLibrary(style: style, backgroundPNG: background)
            if !FileManager.default.fileExists(atPath: url.path) { try? commit(library) }
        }
    }

    var workingStyle: ImageExportStyle {
        guard workingTemplateExists else { return library.selectedTemplate.style }
        return defaults.data(forKey: styleKey).flatMap { try? JSONDecoder().decode(ImageExportStyle.self, from: $0) } ?? library.selectedTemplate.style
    }
    var workingBackgroundPNG: Data? {
        workingTemplateExists ? backgroundCache : library.selectedTemplate.backgroundPNG
    }
    private var workingTemplateExists: Bool {
        guard let value = defaults.string(forKey: workingIDKey) else { return true }
        return library.templates.contains { $0.id.uuidString == value }
    }
    var workingTemplateID: UUID {
        if let value = defaults.string(forKey: workingIDKey).flatMap(UUID.init(uuidString:)), library.templates.contains(where: { $0.id == value }) { return value }
        return library.selectedID
    }
    func saveWorkingConfiguration(style: ImageExportStyle, templateID: UUID, backgroundPNG: Data?) throws {
        let data = try JSONEncoder().encode(style)
        try saveWorkingBackground(backgroundPNG)
        defaults.set(data, forKey: styleKey)
        defaults.set(templateID.uuidString, forKey: workingIDKey)
    }
    func saveWorkingBackground(_ data: Data?) throws {
        if let data, data != backgroundCache || !FileManager.default.fileExists(atPath: workingBackgroundURL.path) {
            try FileManager.default.createDirectory(at: workingBackgroundURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: workingBackgroundURL, options: .atomic)
        }
        defaults.set(data != nil, forKey: backgroundKey)
        backgroundCache = data
    }
    static func image(from data: Data?) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func commit(_ next: ImageExportTemplateLibrary) throws {
        guard next.isValid else { throw CocoaError(.fileWriteUnknown) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        library = next
    }
    @discardableResult func select(_ id: UUID) throws -> ImageExportTemplate {
        guard let template = library.templates.first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
        var next = library; next.selectedID = id; try commit(next)
        return template
    }
    @discardableResult func save(id: UUID? = nil, name: String, style: ImageExportStyle, backgroundPNG: Data?, makeDefault: Bool = false) throws -> ImageExportTemplate {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TemplateError.emptyName }
        guard style.background != .image || Self.image(from: backgroundPNG) != nil else { throw TemplateError.missingBackground }
        guard !library.templates.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw TemplateError.duplicateName }
        let template = ImageExportTemplate(id: id ?? UUID(), name: name, style: style, backgroundPNG: backgroundPNG)
        var next = library
        if let index = next.templates.firstIndex(where: { $0.id == template.id }) { next.templates[index] = template }
        else { next.templates.append(template) }
        next.selectedID = template.id
        if makeDefault { next.defaultID = template.id }
        try commit(next)
        return template
    }
    func rename(_ id: UUID, to name: String) throws {
        guard let template = library.templates.first(where: { $0.id == id }) else { return }
        try save(id: id, name: name, style: template.style, backgroundPNG: template.backgroundPNG)
    }
    /// Put a recoverable copy in the Trash before removing a user template.
    func remove(_ id: UUID) throws {
        guard library.templates.count > 1 else { throw TemplateError.lastTemplate }
        guard let template = library.templates.first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.deletingLastPathComponent().appendingPathComponent("已删除模板-\(UUID().uuidString).hoottemplate")
        try PropertyListEncoder().encode(template).write(to: backup, options: .atomic)
        try trashTemplate(backup)
        var next = library; next.templates.removeAll { $0.id == id }
        if next.defaultID == id { next.defaultID = next.templates[0].id }
        if next.selectedID == id { next.selectedID = next.defaultID }
        try commit(next)
    }

    func renderDefault(_ image: CGImage) -> CGImage? {
        let template = library.defaultTemplate
        let background = template.style.background == .image ? Self.image(from: template.backgroundPNG) : nil
        return ImageExportRenderer.render(image, style: template.style, backgroundImage: background)
    }

    enum TemplateError: LocalizedError {
        case emptyName, duplicateName, missingBackground, lastTemplate
        var errorDescription: String? {
            switch self {
            case .emptyName: "请输入模板名称"
            case .duplicateName: "已有同名模板，请换一个名称"
            case .missingBackground: "请先选择背景图片，再保存模板"
            case .lastTemplate: "至少保留一个模板"
            }
        }
    }
}
