import AppKit
import SwiftUI
import Translation
import ShotPadCore

/// Small popup showing OCR text or a translation.
@MainActor
final class ResultModel: ObservableObject {
    @Published var title: String
    @Published var text = ""
    @Published var busy = true
    @Published var note = ""
    @Published var config: TranslationSession.Configuration?
    var lines: [String] = []
    var engineNote = "本地翻译"

    init(title: String) { self.title = title }

    func runLocal(_ session: TranslationSession) async {
        do {
            let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: "\($0)") }
            let responses = try await session.translations(from: requests)
            var out = [String](repeating: "", count: lines.count)
            for r in responses { if let i = Int(r.clientIdentifier ?? ""), i < out.count { out[i] = r.targetText } }
            text = out.joined(separator: "\n")
            note = engineNote
        } catch {
            text = ""
            note = "翻译失败：\(error.localizedDescription)"
        }
        busy = false
        config = nil
    }
}

struct ResultView: View {
    @ObservedObject var model: ResultModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Group {
                    if model.busy { HStack { ProgressView().controlSize(.small); Text(model.note.isEmpty ? "处理中…" : model.note).foregroundStyle(.secondary) } }
                    else { Text(model.text.isEmpty ? "（无内容）" : model.text).textSelection(.enabled) }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }.disabled(model.text.isEmpty)
                if !model.busy { Text(model.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 320, height: 190)
        .translationTask(model.config) { session in await model.runLocal(session) }
    }
}

@MainActor
enum ResultWindow {
    private static var open: [NSPanel] = []

    @discardableResult
    static func show(title: String) -> ResultModel {
        let model = ResultModel(title: title)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ResultView(model: model) { panel.close() })
        panel.setContentSize(CGSize(width: 320, height: 190))
        let m = NSEvent.mouseLocation
        panel.setFrameTopLeftPoint(CGPoint(x: m.x + 12, y: m.y - 12))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { open.removeAll { $0 === panel } }
        }
        open.append(panel)
        panel.makeKeyAndOrderFront(nil)
        return model
    }
}

/// OCR / translate pipeline shared by the editor and the quick-action bar.
@MainActor
enum TextTools {
    static func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await Task.detached(priority: .userInitiated) { try TextRecognizer.recognize(image) }.value
    }

    /// Returns the recognised text (empty when none).
    static func extractText(_ image: CGImage) async throws -> String {
        TextRecognizer.fullText(try await recognize(image))
    }

    static func showOCR(_ image: CGImage, done: ((Bool) -> Void)? = nil) {
        let model = ResultWindow.show(title: "识别结果")
        model.note = "正在识别…"
        Task {
            do {
                let text = try await extractText(image)
                model.text = text; model.note = text.isEmpty ? "没有识别到文字" : "\(text.count) 字"
                done?(!text.isEmpty)
            } catch { model.note = "识别失败：\(error.localizedDescription)"; done?(false) }
            model.busy = false
        }
    }

    static func showTranslation(_ image: CGImage, toChinese: Bool?, done: ((Bool) -> Void)? = nil) {
        let model = ResultWindow.show(title: "翻译")
        model.note = "正在识别…"
        Task {
            let lines: [String]
            do { lines = try await recognize(image).map(\.text) } catch {
                model.busy = false; model.note = "识别失败：\(error.localizedDescription)"; done?(false); return
            }
            guard !lines.isEmpty else { model.busy = false; model.note = "没有识别到文字"; done?(false); return }
            let target = toChinese ?? !TextRecognizer.isMostlyChinese(lines.joined(separator: "\n"))
            done?(true)
            if let cfg = AppSettings.shared.llm {
                model.note = "正在翻译（\(cfg.model)）…"
                do {
                    let out = try await LLMTranslator.translate(lines: lines, toChinese: target, config: cfg)
                    model.text = out.joined(separator: "\n"); model.note = "大模型 · \(cfg.model)"; model.busy = false
                    return
                } catch {
                    model.engineNote = "大模型失败，已用本地翻译"
                    model.note = "大模型失败，改用本地翻译…"
                }
            } else { model.note = "正在本地翻译…" }
            model.lines = lines
            model.config = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: target ? "zh-Hans" : "en"))
        }
    }

    /// Triggers the one-off system model compile so the first real OCR is fast.
    static func warmUp() {
        let size = CGSize(width: 240, height: 60)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Hello 你好 123" as NSString).draw(at: CGPoint(x: 8, y: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            return true
        }
        var r = CGRect(origin: .zero, size: size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
        Task.detached(priority: .utility) { _ = try? TextRecognizer.recognize(cg) }
    }
}
