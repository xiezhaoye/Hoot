import AppKit
import SwiftUI
import Translation
import ShotPadCore

/// Small popup showing OCR text or a translation.
@MainActor
final class ResultModel: ObservableObject {
    @Published var title: String
    @Published var text = "" { didSet { fitWindow?() } }
    @Published var busy = true { didSet { fitWindow?() } }
    /// Set by the window: resizes it to the current content.
    var fitWindow: (() -> Void)?
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
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                Group {
                    if model.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.note.isEmpty ? "处理中…" : model.note).foregroundStyle(.secondary) } }
                    else { Text(model.text.isEmpty ? "（无内容）" : model.text).textSelection(.enabled) }
                }
                .font(.system(size: 14))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            HStack(spacing: 10) {
                if !model.busy { Text(model.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.text.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .translationTask(model.config) { session in await model.runLocal(session) }
    }
}

@MainActor
enum ResultWindow {
    private static var open: [NSPanel] = []
    private static let width: CGFloat = 460

    @discardableResult
    static func show(title: String) -> ResultModel {
        let model = ResultModel(title: title)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ResultView(model: model) { panel.close() })
        panel.setContentSize(CGSize(width: width, height: 220))
        panel.minSize = CGSize(width: 340, height: 180)
        model.fitWindow = { [weak panel, weak model] in
            guard let panel, let model else { return }
            // text height at the window's width, plus the buttons / paddings around it
            let text = model.busy || model.text.isEmpty ? "处理中…" : model.text
            let font = NSFont.systemFont(ofSize: 14)
            let measured = (text as NSString).boundingRect(with: CGSize(width: panel.contentLayoutRect.width - 36 - 28, height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
            let lines = max(1, Int(measured / font.pointSize))
            let content = measured + CGFloat(lines) * 3 + 28 + 18 * 2 + 14 + 40
            let maxHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
            let height = min(max(220, content), maxHeight * 0.75)
            var frame = panel.frame
            let target = panel.frameRect(forContentRect: CGRect(x: 0, y: 0, width: panel.contentLayoutRect.width, height: height)).height
            frame.origin.y += frame.height - target; frame.size.height = target
            panel.setFrame(frame, display: true, animate: true)
        }
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
    /// QR payloads come first, then the printed text.
    static func extractText(_ image: CGImage) async throws -> String {
        let qr = await Task.detached(priority: .userInitiated) { LinkDetector.qrPayloads(image) }.value
        let printed = TextRecognizer.fullText(try await recognize(image))
        return (qr + (printed.isEmpty ? [] : [printed])).joined(separator: "\n")
    }

    /// A QR code's link wins over printed text.
    static func findURL(_ image: CGImage) async -> URL? {
        let qr = await Task.detached(priority: .userInitiated) { LinkDetector.qrPayloads(image) }.value
        if let url = qr.lazy.compactMap({ LinkDetector.firstURL(in: $0) }).first { return url }
        guard let text = try? await extractText(image) else { return nil }
        return LinkDetector.firstURL(in: text)
    }

    static func openLink(_ image: CGImage, done: @escaping (Bool) -> Void) {
        Task { @MainActor in
            if let url = await findURL(image) { NSWorkspace.shared.open(url); done(true) } else { NSSound.beep(); done(false) }
        }
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
