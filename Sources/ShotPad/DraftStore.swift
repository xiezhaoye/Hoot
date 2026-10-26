import AppKit
import ShotPadCore

@MainActor
enum DraftStore {
    struct Session: Codable {
        var id: UUID
        var documentID: UUID
        var historyID: UUID?
        var frame: String
        var zoom: Int
        var tool: String?
        var savedURL: URL?
        var scrollOrigin: CGPoint?
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotPad/Drafts", isDirectory: true)
    }
    static func documentURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).hootdraft") }
    static func sessionURL(_ id: UUID) -> URL { directory.appendingPathComponent("windows/\(id).plist") }
    static func save(_ model: EditorModel) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try model.doc.archive().write(to: documentURL(model.documentID), options: .atomic)
        let session = Session(id: model.sessionID, documentID: model.documentID, historyID: model.currentID,
                              frame: model.canvas?.window.map { NSStringFromRect($0.frame) } ?? "", zoom: model.zoomPercent, tool: model.tool.rawValue, savedURL: model.savedURL,
                              scrollOrigin: model.canvas?.enclosingScrollView?.contentView.bounds.origin)
        try PropertyListEncoder().encode(session).write(to: sessionURL(model.sessionID), options: .atomic)
    }
    static func load(_ id: UUID) -> EditorDocument? {
        guard let data = try? Data(contentsOf: documentURL(id)) else { return nil }
        return try? EditorDocument.restore(from: data)
    }
    static func sessions() -> [Session] {
        ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("windows"), includingPropertiesForKeys: nil)) ?? []).compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }; return try? PropertyListDecoder().decode(Session.self, from: data)
        }
    }
    static func close(_ id: UUID) { try? FileManager.default.removeItem(at: sessionURL(id)) }
    static func removeDocument(_ id: UUID) { try? FileManager.default.removeItem(at: documentURL(id)) }
}
