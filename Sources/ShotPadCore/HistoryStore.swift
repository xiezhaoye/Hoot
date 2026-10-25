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
    /// File name inside the history folder; entries from older versions have none and use "<id>.png".
    public var fileName: String?

    public init(id: UUID = UUID(), date: Date, width: Int, height: Int, group: HistoryGroup = .normal, fileName: String? = nil) {
        self.id = id; self.date = date; self.width = width; self.height = height; self.group = group; self.fileName = fileName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        group = try c.decodeIfPresent(HistoryGroup.self, forKey: .group) ?? .normal
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
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
            entries = decoded.filter { FileManager.default.fileExists(atPath: file(for: $0).path) }
        }
    }

    private func file(for entry: HistoryEntry) -> URL { directory.appendingPathComponent(entry.fileName ?? "\(entry.id.uuidString).png") }

    private func file(_ id: UUID) -> URL {
        entries.first { $0.id == id }.map(file(for:)) ?? directory.appendingPathComponent("\(id.uuidString).png")
    }

    /// "<prefix> yyyy-MM-dd HH.mm.ss.<ext>", numbered when that name is taken.
    private func uniqueName(prefix: String, date: Date, format: ImageFormat) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(prefix) \(f.string(from: date))"
        var name = "\(base).\(format.fileExtension)", n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) \(n).\(format.fileExtension)"; n += 1
        }
        return name
    }

    @discardableResult
    public func add(_ image: CGImage, date: Date = Date(), group: HistoryGroup = .normal,
                    format: ImageFormat = .png, namePrefix: String = "截图") -> HistoryEntry? {
        let name = uniqueName(prefix: namePrefix, date: date, format: format)
        let entry = HistoryEntry(date: date, width: image.width, height: image.height, group: group, fileName: name)
        guard write(image, to: directory.appendingPathComponent(name)) else { return nil }
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
        let url = file(id)
        entries.removeAll { $0.id == id }
        thumbCache[id] = nil
        try? FileManager.default.removeItem(at: url)
        saveIndex()
    }

    private func prune() {
        while entries.count > limit, let last = entries.last {
            try? FileManager.default.removeItem(at: file(for: last))
            thumbCache[last.id] = nil
            entries.removeLast()
        }
        saveIndex()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func write(_ image: CGImage, to url: URL) -> Bool {
        ImageFormat.from(extension: url.pathExtension).encode(image, to: url)
    }
}
