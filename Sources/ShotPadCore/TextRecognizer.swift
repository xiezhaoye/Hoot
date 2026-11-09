import CoreGraphics
import CoreML
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
    /// 本进程内记住「ANE 路径失败过」，后续直接走 CPU。
    /// **只存在内存里，不写用户偏好**：这可能只是系统的临时抖动
    /// （实测同一台机器上一次 E5RT 失败后，下次又正常），不值得永久降级。
    /// 识别会在多个后台任务里并发调用，用锁保护这个标记。
    private static let cpuLock = NSLock()
    private static var _prefersCPU = false
    private static var prefersCPU: Bool {
        get { cpuLock.lock(); defer { cpuLock.unlock() }; return _prefersCPU }
        set { cpuLock.lock(); _prefersCPU = newValue; cpuLock.unlock() }
    }

    /// Blocking; call from a background queue.
    ///
    /// Vision 默认把文字识别模型编译到神经引擎（ANE）上跑。macOS 上这一步偶发
    /// 失败，系统会打 `E5RT Error: ...precompiled_compute_operation... (Code: 13)`
    /// 并让整个请求抛错——在用户眼里就是「提取文字失败」。模型和图片都是好的，
    /// 换到 CPU 就能跑通（实测 2654×1830 的图 CPU 0.54s、ANE 首次编译要 90s+），
    /// 所以这里失败后回退 CPU，并记住这个选择，别再让用户白等。
    public static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        if prefersCPU { return try perform(image, device: cpuDevice) }
        do {
            return try perform(image, device: nil)
        } catch {
            prefersCPU = true
            return try perform(image, device: cpuDevice)
        }
    }

    /// 从系统列表里取 CPU 设备：`MLComputeDevice.cpu` 的关联值无法公开构造。
    private static var cpuDevice: MLComputeDevice? {
        MLComputeDevice.allComputeDevices.first { if case .cpu = $0 { return true } else { return false } }
    }

    private static func perform(_ image: CGImage, device: MLComputeDevice?) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if let device { request.setComputeDevice(device, for: .main) }
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
