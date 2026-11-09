import XCTest
import CoreGraphics
import CoreML
@testable import ShotPadCore

/// 桌面机上 Vision 偶发 ANE 编译失败（E5RT Code 13）会让 OCR 抛错。
/// 这个测试锁定「换 CPU 设备仍能识别」这个前提——回退方案依赖它。
final class OCRFallbackTests: XCTestCase {
    private func cpuDevice() throws -> MLComputeDevice {
        guard let d = MLComputeDevice.allComputeDevices.first(where: {
            if case .cpu = $0 { return true } else { return false }
        }) else { throw XCTSkip("本机没有可用的 CPU 计算设备") }
        return d
    }

    func testCPUDeviceRecognizesRenderedText() throws {
        _ = try cpuDevice()
        let ctx = CGContext(data: nil, width: 600, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 160))
        let img = NSImage(size: CGSize(width: 600, height: 160))
        img.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        ("CPU FALLBACK 123" as NSString).draw(at: CGPoint(x: 30, y: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        img.unlockFocus()
        var rect = CGRect(x: 0, y: 0, width: 600, height: 160)
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!

        let text = TextRecognizer.fullText(try TextRecognizer.recognize(cg)).uppercased()
        XCTAssertTrue(text.contains("CPU"), "CPU 路径应能识别文字，实际：\(text)")
    }
}
