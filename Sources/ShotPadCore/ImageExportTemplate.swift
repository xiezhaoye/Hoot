import Foundation

public struct ImageExportTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var style: ImageExportStyle
    /// Each template owns its background, independent of the original image file.
    public var backgroundPNG: Data?

    public init(id: UUID = UUID(), name: String, style: ImageExportStyle, backgroundPNG: Data? = nil) {
        self.id = id; self.name = name; self.style = style; self.backgroundPNG = backgroundPNG
    }
}

public struct ImageExportTemplateLibrary: Codable, Equatable {
    public var templates: [ImageExportTemplate]
    public var defaultID: UUID
    public var selectedID: UUID

    public init(style: ImageExportStyle = ImageExportStyle(), backgroundPNG: Data? = nil) {
        let current = ImageExportTemplate(name: "默认模板", style: style, backgroundPNG: backgroundPNG)
        var blue = ImageExportStyle()
        blue.color = RGBA(0.76, 0.86, 0.97); blue.gradientEnd = RGBA(0.94, 0.97, 1)
        blue.padding = 48; blue.cornerRadius = 16
        var paper = ImageExportStyle()
        paper.background = .solid; paper.color = RGBA(0.96, 0.95, 0.92)
        paper.padding = 32; paper.cornerRadius = 8
        templates = [current, ImageExportTemplate(name: "清爽蓝", style: blue), ImageExportTemplate(name: "纸白", style: paper)]
        defaultID = current.id; selectedID = current.id
    }

    public var defaultTemplate: ImageExportTemplate { templates.first { $0.id == defaultID } ?? templates[0] }
    public var selectedTemplate: ImageExportTemplate { templates.first { $0.id == selectedID } ?? defaultTemplate }
    public var isValid: Bool {
        !templates.isEmpty && Set(templates.map(\.id)).count == templates.count &&
        templates.contains { $0.id == defaultID } && templates.contains { $0.id == selectedID }
    }
}
