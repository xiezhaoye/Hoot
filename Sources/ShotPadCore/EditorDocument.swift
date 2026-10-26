import CoreGraphics
import Foundation

/// Pixels and editable objects share the same snapshot/undo lifetime.
public final class EditorDocument {
    public struct State {
        public var base: CGImage
        public var annotations: [Annotation]
        public var patches: [Patch] = []
        public var order: [UUID] = []
    }
    public private(set) var state: State
    public var selectedPatchID: UUID?
    public var patch: Patch? { state.patches.first { $0.id == selectedPatchID } }
    public var patches: [Patch] { state.patches }
    var undoStack: [State] = []
    var redoStack: [State] = []
    public var hiddenAnnotationID: UUID?
    public init(image: CGImage) { state = State(base: image, annotations: []) }
    init(state: State, undo: [State], redo: [State]) { self.state = state; undoStack = undo; redoStack = redo }
    public var size: CGSize { CGSize(width: state.base.width, height: state.base.height) }
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isModified: Bool { !undoStack.isEmpty || !state.annotations.isEmpty || !patches.isEmpty }
    public var hasEditableObjects: Bool { !state.annotations.isEmpty || !patches.isEmpty }
    private var visibleAnnotations: [Annotation] { state.annotations.filter { $0.id != hiddenAnnotationID } }
    /// Current board extent, including editable objects.
    public func rendered() -> CGImage { composite() }
    public func composite(includeEditing: Bool = false) -> CGImage { Renderer.render(base: state.base, annotations: includeEditing ? state.annotations : visibleAnnotations, patches: patches, order: state.order) }
    /// Exports the complete board, expanding white paper around outlying blocks.
    public func flattened() -> CGImage { flattenedState().base }
    public func copyRegion(_ rect: CGRect) -> CGImage? { composite().cropping(to: rect.integral.clamped(to: bounds)) }
    public func record() { undoStack.append(state); redoStack.removeAll() }
    public func add(_ annotation: Annotation) { record(); state.annotations.append(annotation); state.order.append(annotation.id) }
    public func add(_ annotations: [Annotation]) { guard !annotations.isEmpty else { return }; record(); state.annotations += annotations; state.order += annotations.map(\.id) }
    public func annotation(_ id: UUID) -> Annotation? { state.annotations.first { $0.id == id } }
    public func annotation(at point: CGPoint, slop: CGFloat, matching: (Annotation) -> Bool) -> Annotation? {
        state.annotations.last { a in
            guard a.isEditable, matching(a), a.hit(point, slop: slop) else { return false }
            let index = state.order.firstIndex(of: a.id) ?? 0
            return !state.patches.contains { $0.rect.contains(point) && (state.order.firstIndex(of: $0.id) ?? 0) > index }
        }
    }
    public func replaceAnnotation(_ a: Annotation, record shouldRecord: Bool) {
        guard let i = state.annotations.firstIndex(where: { $0.id == a.id }) else { return }
        if shouldRecord { record() }; state.annotations[i] = a
    }
    public func removeAnnotation(_ id: UUID) {
        guard state.annotations.contains(where: { $0.id == id }) else { return }
        record(); state.annotations.removeAll { $0.id == id }; state.order.removeAll { $0 == id }
    }
    public func reorderAnnotation(_ id: UUID, toFront: Bool) {
        guard let i = state.annotations.firstIndex(where: { $0.id == id }), i != (toFront ? state.annotations.count - 1 : 0) else { return }
        record(); let a = state.annotations.remove(at: i); state.annotations.insert(a, at: toFront ? state.annotations.count : 0)
        state.order.removeAll { $0 == id }; state.order.insert(id, at: toFront ? state.order.count : 0)
    }
    /// An opaque mask erases the selected pixels without flattening other objects.
    public func erase(_ rect: CGRect) {
        let r = rect.integral.clamped(to: bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        let ctx = Renderer.makeContext(width: 1, height: 1)
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        var mask = Patch(image: ctx.makeImage()!, rect: r); mask.isMask = true
        record(); state.patches.append(mask); state.order.append(mask.id); selectedPatchID = nil
    }
    public func deletePatch() {
        guard let p = patch else { return }; record()
        state.patches.removeAll { $0.id == p.id }; state.order.removeAll { $0 == p.id }; selectedPatchID = nil
        // Lifted source pixels stay erased; the erase itself remains undoable.
        if let r = p.vacated {
            let hole = Patch(image: p.image, rect: .zero, vacated: r)
            state.base = Renderer.render(base: state.base, annotations: [], patch: hole)
        }
    }
    public func nextNumber() -> Int { (state.annotations.compactMap { a -> Int? in if case .number(let n, _, _) = a.kind { return n }; return nil }.max() ?? 0) + 1 }
    public func crop(to rect: CGRect) {
        let r = rect.integral.clamped(to: bounds)
        guard r.width >= 1, r.height >= 1, let image = state.base.cropping(to: r) else { return }
        record(); state.base = image
        let delta = CGSize(width: -r.minX, height: -r.minY)
        state.annotations = state.annotations.map { var a = $0; a.move(by: delta); return a }
        state.patches = state.patches.compactMap { block in
            let visible = block.rect.intersection(r).integral
            guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
            let local = visible.offsetBy(dx: -block.rect.minX, dy: -block.rect.minY)
            guard let pixels = block.rasterized().cropping(to: local) else { return nil }
            var result = block; result.image = pixels
            result.rect = visible.offsetBy(dx: delta.width, dy: delta.height)
            if let hole = block.vacated {
                let clipped = hole.intersection(r)
                result.vacated = clipped.isNull ? nil : clipped.offsetBy(dx: delta.width, dy: delta.height)
            }
            return result
        }
        let ids = Set(state.annotations.map(\.id) + state.patches.map(\.id)); state.order.removeAll { !ids.contains($0) }
        selectedPatchID = nil
    }
    public func beginPatch(image: CGImage, rect: CGRect) {
        record(); let p = Patch(image: image, rect: rect); state.patches.append(p); state.order.append(p.id); selectedPatchID = p.id
    }
    @discardableResult public func liftSelection(_ rect: CGRect) -> Bool {
        let r = rect.integral.clamped(to: bounds)
        guard r.width >= 1, r.height >= 1, let image = copyRegion(r) else { return false }
        record(); let p = Patch(image: image, rect: r, vacated: r); state.patches.append(p); state.order.append(p.id); selectedPatchID = p.id; return true
    }
    public func paste(_ image: CGImage, centeredAt point: CGPoint) {
        let fit = min(1, size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = max(1, (CGFloat(image.width) * fit).rounded()), h = max(1, (CGFloat(image.height) * fit).rounded())
        beginPatch(image: image, rect: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h).integral)
    }
    public func movePatch(by delta: CGSize) { if let p = patch { setPatchRect(p.rect.offsetBy(dx: delta.width, dy: delta.height)) } }
    public func setPatchRect(_ rect: CGRect, record shouldRecord: Bool = true) {
        guard rect.width >= 1, rect.height >= 1, let i = state.patches.firstIndex(where: { $0.id == selectedPatchID }) else { return }
        if shouldRecord { record() }; state.patches[i].rect = rect
    }
    public func patch(at point: CGPoint, slop: CGFloat) -> Patch? {
        state.patches.last { !$0.isMask && ($0.rect.contains(point) || $0.hitHandle(at: point, slop: slop) != nil) }
    }
    public func patchIsAboveAnnotations(_ patch: Patch, at point: CGPoint, slop: CGFloat) -> Bool {
        let index = state.order.firstIndex(of: patch.id) ?? 0
        return !state.annotations.contains { a in
            a.hit(point, slop: slop) && (state.order.firstIndex(of: a.id) ?? 0) > index
        }
    }
    private func flattenedState() -> State {
        let target = patches.reduce(bounds) { $0.union($1.rect.integral) }.integral
        let shift = CGSize(width: -target.minX, height: -target.minY)
        let base = target == bounds ? state.base : Self.expand(state.base, to: target.size, shifted: CGPoint(x: shift.width, y: shift.height))
        let annotations = state.annotations.map { var a = $0; a.move(by: shift); return a }
        let blocks = patches.map { p -> Patch in var p = p; p.rect = p.rect.offsetBy(dx: shift.width, dy: shift.height); p.vacated = p.vacated?.offsetBy(dx: shift.width, dy: shift.height); return p }
        return State(base: Renderer.render(base: base, annotations: annotations, patches: blocks, order: state.order), annotations: [])
    }
    public func flattenAll() { guard hasEditableObjects else { return }; let result = flattenedState(); record(); state = result; selectedPatchID = nil }
    /// Compatibility entry point: explicit commit now fixes all objects together.
    public func commitPatch() { flattenAll() }
    private static func expand(_ image: CGImage, to size: CGSize, shifted: CGPoint) -> CGImage {
        let ctx = Renderer.makeContext(width: Int(size.width), height: Int(size.height))
        ctx.setFillColor(RGBA.white.cgColor); ctx.fill(CGRect(origin: .zero, size: size))
        ctx.draw(image, in: CGRect(x: shifted.x, y: size.height - shifted.y - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()!
    }
    /// Escape deselects; it never discards an already pasted object.
    public func cancelPatch() { selectedPatchID = nil }
    public func undo() { guard let prev = undoStack.popLast() else { return }; redoStack.append(state); state = prev; selectedPatchID = nil }
    public func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(state); state = next; selectedPatchID = nil }
}
