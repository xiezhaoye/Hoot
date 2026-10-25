import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var date: Date
    public var width: Int
    public var height: Int
}

/// Keeps the most recent screenshots as PNG files plus a small JSON index.
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry] = []   // newest first
    public var limit: Int { didSet { prune() } }
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, limit: Int = 50) {
        self.directory = directory
        self.limit = max(1, limit)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded.filter { FileManager.default.fileExists(atPath: file($0.id).path) }
        }
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    @discardableResult
    public func add(_ image: CGImage, date: Date = Date()) -> HistoryEntry? {
        let entry = HistoryEntry(id: UUID(), date: date, width: image.width, height: image.height)
        guard write(image, to: file(entry.id)) else { return nil }
        entries.insert(entry, at: 0)
        prune()
        saveIndex()
        return entry
    }

    /// Replaces the stored pixels of an existing entry (after editing).
    public func update(_ id: UUID, with image: CGImage) {
        guard let i = entries.firstIndex(where: { $0.id == id }), write(image, to: file(id)) else { return }
        entries[i].width = image.width
        entries[i].height = image.height
        saveIndex()
    }

    public func image(for id: UUID) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(file(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public func thumbnail(for id: UUID, maxPixel: Int = 240) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(file(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: file(id))
        saveIndex()
    }

    private func prune() {
        while entries.count > limit, let last = entries.last {
            try? FileManager.default.removeItem(at: file(last.id))
            entries.removeLast()
        }
        saveIndex()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
