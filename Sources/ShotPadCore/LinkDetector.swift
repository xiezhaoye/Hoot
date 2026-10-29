import CoreGraphics
import Foundation
import Vision

/// QR codes and web links found in a shot.
public enum LinkDetector {
    /// Payload strings of every QR code in the image. Blocking; call from a background queue.
    public static func qrPayloads(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR]
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        var seen = Set<String>()
        return (request.results ?? []).compactMap { $0.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// First http(s) URL in the text; bare domains such as "example.com/a" are accepted and get https://.
    public static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased() else { continue }
            if scheme == "http" || scheme == "https" { return url }
        }
        return nil
    }
}
