import AppKit
import CryptoKit
import ImageIO
import ShotPadCore

/// All expensive work runs off the UI thread; only the final, uncancelled result touches the pasteboard.
@MainActor
final class MobileImageSharing {
    struct PreparedImage: Sendable {
        let image: CGImage
        let png: Data
    }
    static let shared = MobileImageSharing()
    typealias Recognizer = @Sendable (CGImage) throws -> [RecognizedLine]
    private let recognize: Recognizer
    private var cache: [String: [TextParagraph]] = [:]
    private var recent: [String] = []

    init(recognize: @escaping Recognizer = { try TextRecognizer.recognizeForReflow($0) }) { self.recognize = recognize }

    func makeImage(_ image: CGImage, template: ImageExportTemplate,
                   progress: @MainActor (String) -> Void = { _ in }) async throws -> CGImage {
        try Task.checkCancellation()
        progress("正在识别文字…")
        let key = try await worker { try Self.fingerprint(image) }
        try Task.checkCancellation()
        let paragraphs: [TextParagraph]
        if let saved = cache[key] {
            paragraphs = saved
        } else {
            let recognize = self.recognize
            let lines = try await worker { try recognize(image) }
            try Task.checkCancellation()
            progress("正在整理段落…")
            paragraphs = try await worker { MobileTextLayout.paragraphs(from: lines) }
            try Task.checkCancellation()
            guard !paragraphs.isEmpty else { throw MobileTextRenderer.Failure.noText }
            cache[key] = paragraphs
        }
        recent.removeAll { $0 == key }; recent.append(key)
        while recent.count > 3 { cache.removeValue(forKey: recent.removeFirst()) }
        progress("正在生成手机图片…")
        let output = try await worker {
            let background: CGImage?
            if template.style.background == .image, let data = template.backgroundPNG, let source = CGImageSourceCreateWithData(data as CFData, nil) {
                background = CGImageSourceCreateImageAtIndex(source, 0, nil)
            } else { background = nil }
            return try MobileTextRenderer.render(paragraphs, style: template.style, backgroundImage: background)
        }
        try Task.checkCancellation()
        return output
    }

    func copy(_ image: CGImage, template: ImageExportTemplate,
              progress: @MainActor (String) -> Void = { _ in }, beforeCopy: () -> Void = {}) async throws {
        let output = try await prepare(image, template: template, progress: progress)
        try Task.checkCancellation()
        beforeCopy()
        Clipboard.writePNG(output.png)
    }

    func prepare(_ image: CGImage, template: ImageExportTemplate,
                 progress: @MainActor (String) -> Void = { _ in }) async throws -> PreparedImage {
        let output = try await makeImage(image, template: template, progress: progress)
        let png = try await worker {
            guard let data = output.pngData else { throw MobileTextRenderer.Failure.invalidTemplate }
            return data
        }
        try Task.checkCancellation()
        return PreparedImage(image: output, png: png)
    }

    private func worker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try work()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    nonisolated private static func fingerprint(_ image: CGImage) throws -> String {
        let ctx = Renderer.makeContext(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { throw MobileTextRenderer.Failure.noText }
        var hash = SHA256()
        hash.update(data: Data("\(image.width)x\(image.height):".utf8))
        for y in 0..<image.height {
            try Task.checkCancellation()
            let row = Data(bytesNoCopy: data.advanced(by: y * ctx.bytesPerRow), count: image.width * 4, deallocator: .none)
            hash.update(data: row)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
