import AppKit

public enum MobileTextRenderer {
    public static let width = 1080
    public static let bodyFontSize: CGFloat = 48

    public enum Failure: LocalizedError {
        case noText, tooLong, invalidTemplate
        public var errorDescription: String? {
            switch self {
            case .noText: "没有识别到文字，请选择文字清晰的截图区域"
            case .tooLong: "文字内容过长，请分段截图后分享"
            case .invalidTemplate: "无法生成图片，请检查默认模板的背景设置"
            }
        }
    }

    /// Reflow the complete text at a readable font size; do not shrink it or silently drop paragraphs.
    public static func render(_ paragraphs: [TextParagraph], style: ImageExportStyle, backgroundImage: CGImage? = nil) throws -> CGImage {
        guard !paragraphs.isEmpty else { throw Failure.noText }
        guard style.padding.isFinite, style.cornerRadius.isFinite else { throw Failure.invalidTemplate }
        let padding = style.background == .none ? 0 : max(0, min(256, style.padding))
        let paperWidth = CGFloat(width) - padding * 2, margin: CGFloat = 48
        let textWidth = paperWidth - margin * 2
        let text = NSMutableAttributedString(string: "")
        for (index, paragraph) in paragraphs.enumerated() {
            let size = paragraph.kind == .heading ? 60.0 : bodyFontSize
            let font = NSFont.systemFont(ofSize: size, weight: paragraph.kind == .heading ? .semibold : .regular)
            let layout = NSMutableParagraphStyle()
            layout.lineBreakMode = .byWordWrapping
            layout.minimumLineHeight = size * 1.5; layout.maximumLineHeight = size * 1.5
            layout.paragraphSpacing = 24
            if paragraph.kind == .list, let prefix = MobileTextLayout.listPrefix(paragraph.text) {
                layout.headIndent = min(160, (prefix as NSString).size(withAttributes: [.font: font]).width + 8)
            }
            text.append(NSAttributedString(string: paragraph.text + (index < paragraphs.count - 1 ? "\n" : ""), attributes: [
                .font: font, .paragraphStyle: layout,
                .foregroundColor: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
            ]))
        }
        let measured = text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Height follows the text; even a single line keeps breathing room on both sides.
        let height = max(ceil(bodyFontSize * 1.5) + margin * 2, ceil(measured.height) + margin * 2)
        guard height.isFinite, height + padding * 2 <= 32768 else { throw Failure.tooLong }
        let ctx = Renderer.makeContext(width: Int(paperWidth), height: Int(height))
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: paperWidth, height: height))
        ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(with: CGRect(x: margin, y: margin, width: textWidth, height: ceil(measured.height) + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let paper = ctx.makeImage(), let output = ImageExportRenderer.render(paper, style: style, backgroundImage: backgroundImage) else { throw Failure.invalidTemplate }
        return output
    }
}
