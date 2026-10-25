import AppKit
import SwiftUI
import Translation
import ShotPadCore

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct TranslationJob {
    var lines: [RecognizedLine]
    var offset: CGPoint
    var configuration: TranslationSession.Configuration
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var doc: EditorDocument
    @Published var tool: Tool = .select
    @Published var colorValue: Color = Color(red: 0.95, green: 0.2, blue: 0.2)
    @Published var lineWidth: CGFloat = 3
    @Published var fontSize: CGFloat = 28
    @Published var status = ""
    @Published var entries: [HistoryEntry] = []
    @Published var currentID: UUID?
    @Published var ocrText: String?
    @Published var busy = false
    @Published var translationConfig: TranslationSession.Configuration?
    @Published var targetChinese: Bool? = nil    // nil = pick automatically from the recognised text
    @Published var revision = 0                  // bumps whenever the document changes, to refresh undo/redo buttons

    let history: HistoryStore
    weak var canvas: CanvasView?
    private var job: TranslationJob?

    init(image: CGImage, history: HistoryStore, entry: HistoryEntry?) {
        self.doc = EditorDocument(image: image)
        self.history = history
        self.currentID = entry?.id
        self.entries = history.entries
    }

    var color: RGBAWrapper { RGBAWrapper(colorValue) }

    func documentChanged() { revision += 1 }

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
        canvas?.reload()
        status = "已打开历史截图"
    }

    func deleteEntry(_ entry: HistoryEntry) {
        history.remove(entry.id)
        entries = history.entries
        if entry.id == currentID { currentID = nil }
    }

    // MARK: Output

    func copyAll() {
        canvas?.finishPatch()
        Clipboard.write(doc.flattened())
        status = "已复制到剪贴板"
    }

    func saveAs() {
        canvas?.finishPatch()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "截图 \(f.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url, let data = doc.flattened().pngData else { return }
        do { try data.write(to: url); status = "已保存 \(url.lastPathComponent)" } catch { status = "保存失败：\(error.localizedDescription)" }
    }

    func pin() {
        canvas?.finishPatch()
        PinWindow.show(doc.flattened())
    }

    // MARK: OCR / translate

    private func recognitionTarget() -> (image: CGImage, offset: CGPoint) {
        canvas?.finishPatch()
        if let s = canvas?.selectionRect, s.width > 4, s.height > 4, let region = doc.copyRegion(s) {
            return (region, s.integral.origin)
        }
        return (doc.rendered(), .zero)
    }

    func runOCR() {
        let target = recognitionTarget()
        busy = true; status = "正在识别文字…"
        Task.detached {
            let result = Result { try TextRecognizer.recognize(target.image) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let lines):
                    let text = TextRecognizer.fullText(lines)
                    if text.isEmpty { self.status = "没有识别到文字" } else { self.ocrText = text; self.status = "识别到 \(lines.count) 行" }
                case .failure(let e): self.status = "识别失败：\(e.localizedDescription)"
                }
            }
        }
    }

    func translate() {
        let target = recognitionTarget()
        busy = true; status = "正在识别并翻译…"
        Task.detached {
            let result = Result { try TextRecognizer.recognize(target.image) }
            await MainActor.run {
                switch result {
                case .success(let lines) where !lines.isEmpty:
                    let chinese = TextRecognizer.isMostlyChinese(TextRecognizer.fullText(lines))
                    let toChinese = self.targetChinese ?? !chinese
                    let config = TranslationSession.Configuration(source: nil,
                        target: Locale.Language(identifier: toChinese ? "zh-Hans" : "en"))
                    self.job = TranslationJob(lines: lines, offset: target.offset, configuration: config)
                    self.translationConfig = nil
                    self.translationConfig = config
                case .success: self.busy = false; self.status = "没有识别到文字"
                case .failure(let e): self.busy = false; self.status = "识别失败：\(e.localizedDescription)"
                }
            }
        }
    }

    /// Called from the SwiftUI translation task with the system session.
    func performTranslation(_ session: TranslationSession) async {
        guard let job else { return }
        do {
            let requests = job.lines.enumerated().map { TranslationSession.Request(sourceText: $1.text, clientIdentifier: "\($0)") }
            let responses = try await session.translations(from: requests)
            var out = [String](repeating: "", count: job.lines.count)
            for r in responses { if let i = Int(r.clientIdentifier ?? ""), i < out.count { out[i] = r.targetText } }
            let image = doc.rendered()
            let shifted = job.lines.map { RecognizedLine(text: $0.text, rect: $0.rect.offsetBy(dx: job.offset.x, dy: job.offset.y)) }
            let overlays = TextRecognizer.overlays(lines: shifted, translations: out, over: image)
            doc.add(overlays)
            canvas?.refresh()
            status = "已翻译 \(overlays.count) 处文字（⌘Z 可还原）"
        } catch {
            status = "翻译失败：\(error.localizedDescription)"
        }
        busy = false
        self.job = nil
    }
}

struct RGBAWrapper {
    let rgba: RGBA
    var nsColor: NSColor { rgba.nsColor }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .red
        rgba = RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
