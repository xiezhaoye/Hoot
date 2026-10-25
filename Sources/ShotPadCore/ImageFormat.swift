import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File formats ImageIO can write. (WebP is read-only on macOS, so it is not offered.)
public enum ImageFormat: String, CaseIterable, Codable {
    case png, jpeg, heic, tiff, bmp, gif, jpeg2000

    public var title: String {
        switch self {
        case .png: return "PNG（无损，推荐）"
        case .jpeg: return "JPG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .gif: return "GIF"
        case .jpeg2000: return "JPEG 2000"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .bmp: return "bmp"
        case .gif: return "gif"
        case .jpeg2000: return "jp2"
        }
    }

    public var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .jpeg2000: return UTType("public.jpeg-2000") ?? .jpeg
        }
    }

    /// Format that matches a file extension, falling back to PNG.
    public static func from(extension ext: String) -> ImageFormat {
        let e = ext.lowercased()
        if e == "jpeg" { return .jpeg }
        if e == "tif" { return .tiff }
        return allCases.first { $0.fileExtension == e } ?? .png
    }

    private var needsOpaque: Bool { self == .jpeg || self == .jpeg2000 || self == .bmp || self == .gif }

    public func encode(_ image: CGImage, to url: URL) -> Bool {
        let source = needsOpaque ? Self.opaque(image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var options: [CFString: Any] = [:]
        if self == .jpeg || self == .heic || self == .jpeg2000 { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, source, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Copy on a white background, for formats without alpha.
    static func opaque(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage() ?? image
    }
}
