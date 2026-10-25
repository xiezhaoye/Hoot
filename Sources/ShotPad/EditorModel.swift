import AppKit
import SwiftUI
import ShotPadCore

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var doc: EditorDocument
    @Published var tool: Tool = .hand            // .hand = no tool picked: drag to pan
    @Published var zoomPercent = 100
    @Published var zoomFitted = false
    @Published var colorValue: Color = AppSettings.shared.annotationColor {
        didSet { AppSettings.shared.annotationColor = colorValue; canvas?.styleChanged(.color) }
    }
    @Published var lineWidth: CGFloat = 3 { didSet { canvas?.styleChanged(.width) } }
    @Published var fontSize: CGFloat = 28 { didSet { canvas?.styleChanged(.font) } }
    @Published var fill: Annotation.Fill = .none { didSet { canvas?.styleChanged(.appearance) } }
    @Published var opacity: Double = 1 { didSet { canvas?.styleChanged(.appearance) } }
    @Published var cornerRadius: CGFloat = 0 { didSet { canvas?.styleChanged(.appearance) } }
    @Published var shadow = false { didSet { canvas?.styleChanged(.appearance) } }
    @Published var aspectLocked = false
    @Published var sidebarVisible = true
    @Published var inspectorVisible = true
    @Published var status = ""
    @Published var entries: [HistoryEntry] = []
    @Published var currentID: UUID?
    @Published var busy = false
    @Published var targetChinese: Bool? = nil    // nil = pick automatically from the recognised text
    @Published var revision = 0                  // bumps whenever the document changes, to refresh undo/redo buttons

    let history: HistoryStore
    weak var canvas: CanvasView?

    init(image: CGImage, history: HistoryStore, entry: HistoryEntry?) {
        self.doc = EditorDocument(image: image)
        self.history = history
        self.currentID = entry?.id
        self.entries = history.entries
    }

    var color: RGBAWrapper { RGBAWrapper(colorValue) }

    func documentChanged() { revision += 1 }

    var hasPatch: Bool { revision >= 0 && doc.patch != nil }

    var currentEntry: HistoryEntry? { entries.first { $0.id == currentID } }
    var documentTitle: String { currentEntry?.shortName ?? "未命名画板" }
    var selectedAnnotation: Annotation? { revision >= 0 ? canvas?.selectedAnnotation : nil }
    var selectionFrame: CGRect? { doc.patch?.rect ?? selectedAnnotation?.bounds ?? canvas?.activeSelectionRect }
    var canEditFrame: Bool { selectedAnnotation != nil || hasPatch }

    func applyAppearance(to annotation: Annotation) -> Annotation {
        var result = annotation
        result.fill = fill; result.opacity = opacity; result.cornerRadius = cornerRadius; result.shadow = shadow
        return result
    }

    func updateFrame(_ value: CGFloat, keyPath: WritableKeyPath<CGRect, CGFloat>) {
        guard value.isFinite, var frame = selectionFrame, canEditFrame else { return }
        var locked = aspectLocked
        if !hasPatch, let annotation = selectedAnnotation, case .number = annotation.kind { locked = true }
        if keyPath == \.size.width {
            let width = max(1, value)
            if locked { frame.size.height *= width / max(1, frame.width) }
            frame.size.width = width
        } else if keyPath == \.size.height {
            let height = max(1, value)
            if locked { frame.size.width *= height / max(1, frame.height) }
            frame.size.height = height
        } else { frame[keyPath: keyPath] = value }
        if hasPatch { doc.setPatchRect(frame); canvas?.needsDisplay = true }
        else { canvas?.setSelectedFrame(frame) }
    }

    func chooseTool(_ next: Tool) {
        canvas?.finishTextEditing()
        tool = tool == next && next != .hand ? .hand : next
        canvas?.needsDisplay = true
        if let canvas { canvas.window?.invalidateCursorRects(for: canvas); canvas.window?.makeFirstResponder(canvas) }
    }

    // MARK: History

    /// Writes the edited picture back to its history entry.
    func persistCurrent() {
        guard let id = currentID, doc.isModified || doc.patch != nil else { return }
        history.update(id, with: doc.flattened())
        entries = history.entries
    }

    func open(_ entry: HistoryEntry) {
        guard entry.id != currentID, let image = history.image(for: entry.id) else { return }
        persistCurrent()
        doc = EditorDocument(image: image)
        currentID = entry.id
        canvas?.reload(resetScroll: true)
        status = "已打开历史截图"
    }

    /// A new empty white board of the size set in the settings.
    func newBlank() {
        guard let img = Board.blank(size: AppSettings.shared.boardSize),
              let entry = history.add(img, format: AppSettings.shared.imageFormat, namePrefix: "画板") else { return }
        entries = history.entries
        open(entry)
        status = "已新建空白画板"
    }

    func deleteEntry(_ entry: HistoryEntry) {
        history.remove(entry.id)
        entries = history.entries
        if entry.id == currentID { currentID = nil }
    }

    // MARK: Output

    func copyAll() {
        Clipboard.write(doc.flattened())
        status = "已复制到剪贴板"
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "截图 \(f.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url, let data = doc.flattened().pngData else { return }
        do { try data.write(to: url); status = "已保存 \(url.lastPathComponent)" } catch { status = "保存失败：\(error.localizedDescription)" }
    }

    func pin() {
        PinWindow.show(doc.flattened())
    }

    // MARK: OCR / translate

    /// Floating blocks stay floating: they are included in the output without being baked into the document.
    private func recognitionTarget() -> CGImage {
        let full = doc.flattened()
        if let s = canvas?.selectionRect, s.width > 4, s.height > 4,
           let region = full.cropping(to: s.integral.intersection(doc.bounds)) { return region }
        return full
    }

    func runOCR() { TextTools.showOCR(recognitionTarget()) }

    func translate() { TextTools.showTranslation(recognitionTarget(), toChinese: targetChinese) }
}

extension HistoryEntry {
    var displayName: String {
        guard let fileName else { return "截图" }
        return (fileName as NSString).deletingPathExtension
    }
    var shortName: String {
        if displayName.hasPrefix("截图 ") { return "截图" }
        if displayName.hasPrefix("画板 ") { return "空白画板" }
        if displayName.hasPrefix("图片 ") { return "导入图片" }
        return displayName.replacingOccurrences(of: " \\d{4}-\\d{2}-\\d{2} \\d{2}\\.\\d{2}\\.\\d{2}( \\d+)?$", with: "", options: .regularExpression)
    }
    var formatLabel: String { fileName.map { ($0 as NSString).pathExtension.uppercased() } ?? "PNG" }
}

struct RGBAWrapper {
    let rgba: RGBA
    var nsColor: NSColor { rgba.nsColor }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .red
        rgba = RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
