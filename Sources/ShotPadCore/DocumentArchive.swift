import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A versioned lossless draft. Shared bitmap references are encoded only once,
/// including across undo states; object IDs and undo/redo survive a restart.
private struct DocumentArchive: Codable {
    struct Block: Codable { var id: UUID; var image: Int; var rect: CGRect; var vacated: CGRect?; var isMask: Bool? }
    struct Snapshot: Codable { var base: Int; var annotations: [Annotation]; var patches: [Block]; var order: [UUID] }
    var version = 1
    var images: [Data]
    var state: Snapshot
    var undo: [Snapshot]
    var redo: [Snapshot]
    var selectedPatchID: UUID?
}
public extension EditorDocument {
    func archive() throws -> Data {
        var images: [Data] = [], indices: [ObjectIdentifier: Int] = [:]
        func imageIndex(_ image: CGImage) throws -> Int {
            let key = ObjectIdentifier(image)
            if let i = indices[key] { return i }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            let i = images.count; images.append(data as Data); indices[key] = i; return i
        }
        func snapshot(_ state: State) throws -> DocumentArchive.Snapshot {
            try .init(base: imageIndex(state.base), annotations: state.annotations, patches: state.patches.map {
                try .init(id: $0.id, image: imageIndex($0.image), rect: $0.rect, vacated: $0.vacated, isMask: $0.isMask)
            }, order: state.order)
        }
        let current = try snapshot(state), undo = try undoStack.map(snapshot), redo = try redoStack.map(snapshot)
        let archive = DocumentArchive(images: images, state: current, undo: undo, redo: redo, selectedPatchID: selectedPatchID)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(archive)
    }
    static func restore(from data: Data) throws -> EditorDocument {
        let archive = try PropertyListDecoder().decode(DocumentArchive.self, from: data)
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let images = try archive.images.map { data -> CGImage in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }; return image
        }
        func snapshot(_ s: DocumentArchive.Snapshot) throws -> State {
            func image(_ index: Int) throws -> CGImage { guard images.indices.contains(index) else { throw CocoaError(.fileReadCorruptFile) }; return images[index] }
            let blocks = try s.patches.map { b -> Patch in var p = Patch(image: try image(b.image), rect: b.rect, vacated: b.vacated); p.id = b.id; p.isMask = b.isMask ?? false; return p }
            return State(base: try image(s.base), annotations: s.annotations, patches: blocks, order: s.order)
        }
        let doc = try EditorDocument(state: snapshot(archive.state), undo: archive.undo.map(snapshot), redo: archive.redo.map(snapshot))
        doc.selectedPatchID = archive.selectedPatchID; return doc
    }
}
