import Foundation
import CoreGraphics

public struct TextParagraph: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case body, heading, list }
    public var text: String
    public var kind: Kind
    public init(_ text: String, kind: Kind = .body) { self.text = text; self.kind = kind }
}

/// Restore paragraphs from OCR geometry before wrapping them to a new width.
public enum MobileTextLayout {
    public static func paragraphs(from observations: [RecognizedLine]) -> [TextParagraph] {
        let clean = observations.compactMap { line -> RecognizedLine? in
            let text = line.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty, line.rect.width > 0, line.rect.height > 0,
                  line.rect.minX.isFinite, line.rect.minY.isFinite else { return nil }
            return RecognizedLine(text: text, rect: line.rect)
        }
        guard !clean.isEmpty else { return [] }
        let height = quantile(clean.map { $0.rect.height }, at: 0.5)
        // OCR can return separate observations for styled fragments on the same visual line.
        var groups: [(rect: CGRect, lines: [RecognizedLine])] = []
        for line in clean.sorted(by: { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }) {
            if let index = groups.indices.last(where: { index in
                let r = groups[index].rect
                let overlap = min(r.maxY, line.rect.maxY) - max(r.minY, line.rect.minY)
                return overlap >= min(r.height, line.rect.height) * 0.55
            }) {
                groups[index].lines.append(line); groups[index].rect = groups[index].rect.union(line.rect)
            } else { groups.append((line.rect, [line])) }
        }
        var rows: [RecognizedLine] = []
        for group in groups {
            var fragments: [RecognizedLine] = []
            for line in group.lines.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                if let previous = fragments.last, line.rect.minX - previous.rect.maxX <= height * 2 {
                    let intersection = previous.rect.intersection(line.rect)
                    let area = min(previous.rect.width * previous.rect.height, line.rect.width * line.rect.height)
                    if previous.text == line.text && !intersection.isNull && intersection.width * intersection.height >= area * 0.75 { continue }
                    fragments[fragments.count - 1] = RecognizedLine(text: join(previous.text, line.text), rect: previous.rect.union(line.rect))
                } else { fragments.append(line) }
            }
            rows += fragments
        }
        let gaps = zip(rows, rows.dropFirst()).map { $1.rect.minY - $0.rect.maxY }.filter { $0 >= 0 }
        let regularGap = min(height * 0.6, quantile(gaps, at: 0.35))
        let breakGap = max(height * 0.45, regularGap * 1.65 + height * 0.05)
        let left = quantile(rows.map { $0.rect.minX }, at: 0.15)
        let right = quantile(rows.map { $0.rect.maxX }, at: 0.85)
        var result: [TextParagraph] = []
        var paragraphLefts: [CGFloat] = []
        for (index, line) in rows.enumerated() {
            let kind: TextParagraph.Kind = listPrefix(line.text) != nil ? .list :
                (line.rect.height >= height * 1.35 && line.text.count <= 100 ? .heading : .body)
            guard index > 0, let previousParagraph = result.last else {
                result.append(TextParagraph(line.text, kind: kind)); paragraphLefts.append(line.rect.minX); continue
            }
            let previous = rows[index - 1]
            let gap = line.rect.minY - previous.rect.maxY
            let indentedStart = previousParagraph.kind != .list && line.rect.minX - left > height * 0.8 && previous.rect.minX - left < height * 0.4
            let shortSentence = previousParagraph.kind == .body && previous.rect.maxX - left < max(height, right - left) * 0.65 &&
                previous.text.last.map { "。！？.!?".contains($0) } == true
            let leavesList = previousParagraph.kind == .list && kind != .list && line.rect.minX <= (paragraphLefts.last ?? left) + height * 0.25
            let separate = kind == .list || kind == .heading || previousParagraph.kind == .heading ||
                gap > breakGap || gap < -height * 0.3 || indentedStart || shortSentence || leavesList
            if separate { result.append(TextParagraph(line.text, kind: kind)); paragraphLefts.append(line.rect.minX) }
            else { result[result.count - 1].text = join(previousParagraph.text, line.text) }
        }
        return result
    }

    public static func listPrefix(_ text: String) -> String? {
        let pattern = #"^(?:[•●○▪◦]\s*|[-*]\s+|(?:\d{1,3}|[一二三四五六七八九十百]+)[、．.)）](?!\d)\s*|[（(](?:\d{1,3}|[一二三四五六七八九十百]+)[)）]\s*)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func quantile(_ values: [CGFloat], at fraction: Double) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * fraction)]
    }
    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x2E80...0xA4CF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
    }
    private static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        if last == "\u{00ad}" { return String(left.dropLast()) + right }
        if last == "-" { return left + right } // Preserve real hyphens; do not guess whether a word was hyphenated.
        let wordBoundary = !isCJK(last) && !isCJK(first) &&
            (last.isLetter || last.isNumber || ",.;:!?\"”’)]}".contains(last)) && (first.isLetter || first.isNumber)
        return left + (wordBoundary ? " " : "") + right
    }
}
