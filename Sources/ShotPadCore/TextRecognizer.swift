import CoreGraphics
import Foundation
import Vision

public struct RecognizedLine {
    public var text: String
    /// Image pixels, top-left origin.
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public enum TextRecognizer {
    /// Blocking; call from a background queue.
    public static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let bb = obs.boundingBox
            return RecognizedLine(text: text, rect: CGRect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h))
        }
        .sorted { a, b in abs(a.rect.minY - b.rect.minY) > a.rect.height / 2 ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX }
    }

    public static func fullText(_ lines: [RecognizedLine]) -> String { lines.map(\.text).joined(separator: "\n") }

    /// True when most letters/ideographs are Chinese — used to pick a default translation direction.
    public static func isMostlyChinese(_ text: String) -> Bool {
        var cjk = 0, other = 0
        for u in text.unicodeScalars where u.properties.isAlphabetic {
            if (0x4E00...0x9FFF).contains(u.value) { cjk += 1 } else { other += 1 }
        }
        return cjk > other
    }

    /// Turns OCR lines and their translations into overlay annotations that cover the originals.
    public static func overlays(lines: [RecognizedLine], translations: [String], over image: CGImage) -> [Annotation] {
        zip(lines, translations).compactMap { line, translated in
            let t = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let box = line.rect.insetBy(dx: -2, dy: -1)
            let bg = Renderer.dominantColor(in: image, rect: box)
            let fg: RGBA = bg.luminance > 0.55 ? .black : .white
            return Annotation(.textBox(t, rect: box, background: bg), color: fg)
        }
    }
}
