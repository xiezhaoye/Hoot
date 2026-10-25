import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum HistoryGroup: String, Codable, CaseIterable {
    case normal, ocr, translate
}

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var date: Date
    public var width: Int
    public var height: Int
    public var group: HistoryGroup

    public init(id: UUID = UUID(), date: Date, width: Int, height: Int, group: HistoryGroup = .normal) {
        self.id = id; self.date = date; self.width = width; self.height = height; self.group = group
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        group = try c.decodeIfPresent(HistoryGroup.self, forKey: .group) ?? .normal
    }
}

/// Keeps the most recent screenshots as PNG files plus a small JSON index.
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry] = []   // newest first
    public var limit: Int { didSet { prune() } }
    private let directory: URL
    private var thumbCache: [UUID: CGImage] = [:]
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
    public func add(_ image: CGImage, date: Date = Date(), group: HistoryGroup = .normal) -> HistoryEntry? {
        let entry = HistoryEntry(date: date, width: image.width, height: image.height, group: group)
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
        thumbCache[id] = nil
        saveIndex()
    }

    public func setGroup(_ id: UUID, _ group: HistoryGroup) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].group != group else { return }
        entries[i].group = group
        saveIndex()
    }

    public func image(for id: UUID) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(file(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Decoded once per entry and kept until the entry changes or goes away.
    public func thumbnail(for id: UUID, maxPixel: Int = 240) -> CGImage? {
        if let cached = thumbCache[id] { return cached }
        guard let src = CGImageSourceCreateWithURL(file(id) as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        thumbCache[id] = thumb
        return thumb
    }

    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        thumbCache[id] = nil
        try? FileManager.default.removeItem(at: file(id))
        saveIndex()
    }

    private func prune() {
        while entries.count > limit, let last = entries.last {
            try? FileManager.default.removeItem(at: file(last.id))
            thumbCache[last.id] = nil
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
