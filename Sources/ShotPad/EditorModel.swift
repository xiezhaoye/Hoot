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
    @Published var numberDiameter: CGFloat = max(64, UserDefaults.standard.double(forKey: "numberDiameter")) {
        didSet { UserDefaults.standard.set(numberDiameter, forKey: "numberDiameter") }
    }
    let sessionID = UUID()
    private let scratchID = UUID()
    var documentID: UUID { currentID ?? scratchID }
    private var draftTimer: Timer?
    var savedURL: URL?
    var restoredView: (zoom: Int, origin: CGPoint?)?
    @Published var aspectLocked = false
    @Published var sidebarVisible = true
    @Published var inspectorVisible = false
    @Published var status = ""
    @Published var entries: [HistoryEntry] = []
    @Published var currentID: UUID?
    @Published var busy = false
    @Published var targetChinese: Bool? = nil    // nil = pick automatically from the recognised text
    @Published var revision = 0                  // bumps whenever the document changes, to refresh undo/redo buttons

    let history: HistoryStore
    weak var canvas: CanvasView?

    init(image: CGImage, history: HistoryStore, entry: HistoryEntry?) {
        self.doc = entry.flatMap { DraftStore.load($0.id) } ?? EditorDocument(image: image)
        self.history = history
        self.currentID = entry?.id
        self.entries = history.entries
    }

    var color: RGBAWrapper { RGBAWrapper(colorValue) }

    func documentChanged() {
        revision += 1
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do { try DraftStore.save(self) } catch { self.status = "草稿保存失败：\(error.localizedDescription)" }
            }
        }
    }
    func checkpoint() throws { draftTimer?.invalidate(); try DraftStore.save(self) }

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
        if hasPatch { doc.setPatchRect(frame); canvas?.refresh() }
        else { canvas?.setSelectedFrame(frame) }
    }

    /// Colour, stroke and so on are remembered per tool: a red 4 px arrow and a blue 5 px rectangle can coexist.
    struct DrawStyle {
        var color: Color; var lineWidth: CGFloat; var fontSize: CGFloat
        var fill: Annotation.Fill; var opacity: Double; var cornerRadius: CGFloat; var shadow: Bool
    }
    private var toolStyles: [Tool: DrawStyle] = [:]
    func rememberStyle(for tool: Tool) {
        guard tool.usesColor || tool.usesWidth else { return }
        toolStyles[tool] = DrawStyle(color: colorValue, lineWidth: lineWidth, fontSize: fontSize, fill: fill, opacity: opacity, cornerRadius: cornerRadius, shadow: shadow)
    }
    func restoreStyle(for tool: Tool) {
        guard let st = toolStyles[tool] else { return }
        let previous = canvas?.suppressStyle ?? false
        canvas?.suppressStyle = true
        colorValue = st.color; lineWidth = st.lineWidth; fontSize = st.fontSize
        fill = st.fill; opacity = st.opacity; cornerRadius = st.cornerRadius; shadow = st.shadow
        canvas?.suppressStyle = previous
    }

    func chooseTool(_ next: Tool) {
        canvas?.finishTextEditing()
        rememberStyle(for: tool)
        let target: Tool = tool == next && next != .hand ? .hand : next
        tool = target
        restoreStyle(for: target)
        canvas?.needsDisplay = true
        if let canvas { canvas.window?.invalidateCursorRects(for: canvas); canvas.window?.makeFirstResponder(canvas) }
    }

    // MARK: History

    /// Writes the edited picture back to its history entry.
    func persistCurrent() {
        canvas?.finishTextEditing()
        if currentID == nil, doc.isModified, let entry = history.add(doc.flattened(), format: AppSettings.shared.imageFormat, namePrefix: "画板") { currentID = entry.id }
        do { try checkpoint() } catch { status = "草稿保存失败：\(error.localizedDescription)" }
        guard let id = currentID, doc.isModified else { return }
        history.update(id, with: doc.flattened())
        entries = history.entries
    }

    func open(_ entry: HistoryEntry) {
        guard entry.id != currentID, let image = history.image(for: entry.id) else { return }
        persistCurrent()
        doc = DraftStore.load(entry.id) ?? EditorDocument(image: image)
        savedURL = nil
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
        DraftStore.removeDocument(entry.id)
        entries = history.entries
        if entry.id == currentID { currentID = nil }
    }

    // MARK: Output

    func copyAll() {
        Clipboard.write(doc.flattened())
        status = "已复制到剪贴板"
    }

    /// Replaces the document shown in this (the only) editor window.
    func load(doc newDoc: EditorDocument, entry: HistoryEntry?) {
        persistCurrent()
        doc = newDoc
        savedURL = nil
        currentID = entry?.id
        entries = history.entries
        tool = .hand
        canvas?.reload(resetScroll: true)
        documentChanged()
    }

    func fixAll() {
        canvas?.finishTextEditing(); doc.flattenAll(); canvas?.reload(keepView: true)
        persistCurrent()
        canvas?.window?.makeFirstResponder(canvas)
        status = "已固定全部，可用 ⌘Z 恢复编辑"
    }

    func saveAs() {
        canvas?.finishTextEditing()
        var destination = savedURL
        if destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            panel.nameFieldStringValue = "截图 \(f.string(from: Date())).png"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard let url = destination, let data = doc.flattened().pngData else { status = "保存失败：无法生成图片"; return }
        do {
            try data.write(to: url, options: .atomic)
            doc.flattenAll(); savedURL = url; canvas?.reload(keepView: true)
            persistCurrent(); canvas?.window?.makeFirstResponder(canvas); status = "已保存 \(url.lastPathComponent)，⌘Z 可恢复对象编辑"
        } catch { status = "保存失败：\(error.localizedDescription)" }
    }

    func pin() {
        PinWindow.show(doc.flattened())
    }

    // MARK: OCR / translate

    /// Floating blocks stay floating: they are included in the output without being baked into the document.
    private func recognitionTarget() -> CGImage {
        let full = doc.flattened()
        if let s = canvas?.selectionRect, s.width > 4, s.height > 4,
           let region = doc.composite(includeEditing: true).cropping(to: s.integral.intersection(doc.bounds)) { return region }
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
