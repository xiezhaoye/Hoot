import AppKit
import SwiftUI
import ShotPadCore

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var doc: EditorDocument
    @Published var tool: Tool = .select
    @Published var colorValue: Color = AppSettings.shared.annotationColor {
        didSet { AppSettings.shared.annotationColor = colorValue; canvas?.styleChanged(.color) }
    }
    @Published var lineWidth: CGFloat = 3 { didSet { canvas?.styleChanged(.width) } }
    @Published var fontSize: CGFloat = 28 { didSet { canvas?.styleChanged(.font) } }
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

struct RGBAWrapper {
    let rgba: RGBA
    var nsColor: NSColor { rgba.nsColor }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .red
        rgba = RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
