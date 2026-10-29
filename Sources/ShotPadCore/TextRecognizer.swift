import CoreGraphics
import Foundation
import Vision

public struct RecognizedLine: Sendable {
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

    /// OCR long images at their original resolution, with overlapping strips so line boundaries stay readable.
    /// Called on a worker task; cancellation is checked between Vision requests.
    public static func recognizeForReflow(_ image: CGImage) throws -> [RecognizedLine] {
        var lines: [RecognizedLine] = []
        for tile in reflowTiles(width: image.width, height: image.height) {
            try Task.checkCancellation()
            guard let crop = image.cropping(to: tile.rect) else { continue }
            let found = try recognize(crop)
            try Task.checkCancellation()
            lines += found.compactMap { line in
                let global = line.rect.offsetBy(dx: 0, dy: tile.rect.minY)
                guard global.midY >= tile.ownedRange.lowerBound, global.midY < tile.ownedRange.upperBound else { return nil }
                return RecognizedLine(text: line.text, rect: global)
            }
        }
        return lines
    }

    public struct ReflowTile {
        public var rect: CGRect
        public var ownedRange: Range<CGFloat>
    }
    public static func reflowTiles(width: Int, height: Int) -> [ReflowTile] {
        guard width > 0, height > 0 else { return [] }
        let tileHeight = max(1200, min(3200, width * 2)), overlap = 128
        var tiles: [ReflowTile] = [], top = 0
        while top < height {
            let bottom = min(height, top + tileHeight)
            tiles.append(ReflowTile(rect: CGRect(x: 0, y: top, width: width, height: bottom - top),
                ownedRange: CGFloat(top == 0 ? 0 : top + overlap / 2)..<CGFloat(bottom == height ? height : bottom - overlap / 2)))
            if bottom == height { break }
            top = bottom - overlap
        }
        return tiles
    }

    /// True when most letters/ideographs are Chinese — used to pick a default translation direction.
    public static func isMostlyChinese(_ text: String) -> Bool {
        var cjk = 0, other = 0
        for u in text.unicodeScalars where u.properties.isAlphabetic {
            if (0x4E00...0x9FFF).contains(u.value) { cjk += 1 } else { other += 1 }
        }
        return cjk > other
    }
}
