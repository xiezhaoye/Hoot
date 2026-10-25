import Foundation

public struct BrowseFolder: Codable, Identifiable, Equatable {
    public var id: UUID
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { url.lastPathComponent }
    public var exists: Bool { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue }
}

public struct BrowseGroup: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var folders: [BrowseFolder]

    public init(id: UUID = UUID(), name: String, folders: [BrowseFolder] = []) {
        self.id = id
        self.name = name
        self.folders = folders
    }
}

/// Groups of folders for the 浏览 tab. Only paths are stored; images stay where they are.
public final class BrowseStore {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]

    public private(set) var groups: [BrowseGroup] = []
    private let file: URL

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let g = try? JSONDecoder().decode([BrowseGroup].self, from: data) { groups = g }
    }

    @discardableResult
    public func addGroup(_ name: String) -> BrowseGroup {
        let g = BrowseGroup(name: name)
        groups.append(g)
        save()
        return g
    }

    public func renameGroup(_ id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
        save()
    }

    public func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    /// Returns nil when the folder is already in that group.
    @discardableResult
    public func addFolder(_ url: URL, to groupID: UUID) -> BrowseFolder? {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let path = url.standardizedFileURL.path
        guard !groups[i].folders.contains(where: { $0.path == path }) else { return nil }
        let f = BrowseFolder(path: path)
        groups[i].folders.append(f)
        save()
        return f
    }

    public func removeFolder(_ id: UUID, from groupID: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].folders.removeAll { $0.id == id }
        save()
    }

    /// Images directly inside the folder (no sub-folders, no hidden files), sorted like Finder.
    public static func images(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(groups) { try? data.write(to: file, options: .atomic) }
    }
}
