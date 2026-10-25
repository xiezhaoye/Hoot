import CoreGraphics
import Foundation

/// Editing state for one screenshot: base pixels, annotations, a floating patch and undo history.
public final class EditorDocument {
    public struct State {
        public var base: CGImage
        public var annotations: [Annotation]
    }

    public private(set) var state: State
    public private(set) var patch: Patch?
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    public init(image: CGImage) {
        state = State(base: image, annotations: [])
    }

    public var size: CGSize { CGSize(width: state.base.width, height: state.base.height) }
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }
    public var canUndo: Bool { patch != nil || !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isModified: Bool { !undoStack.isEmpty }

    /// Base + annotations, without the floating patch.
    public func rendered() -> CGImage { Renderer.render(base: state.base, annotations: visibleAnnotations) }

    /// An annotation being re-typed is hidden from the rendering while its text field is open.
    public var hiddenAnnotationID: UUID?

    private var visibleAnnotations: [Annotation] { state.annotations.filter { $0.id != hiddenAnnotationID } }

    /// Everything, including a patch that has not been committed yet.
    public func flattened() -> CGImage { Renderer.render(base: state.base, annotations: visibleAnnotations, patch: patch) }

    /// Pixels of `rect` from the current rendering.
    public func copyRegion(_ rect: CGRect) -> CGImage? {
        rendered().cropping(to: rect.integral.clamped(to: bounds))
    }

    // MARK: - Mutations

    private func record() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    public func add(_ annotation: Annotation) {
        record()
        state.annotations.append(annotation)
    }

    public func add(_ annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        record()
        state.annotations.append(contentsOf: annotations)
    }

    public func annotation(_ id: UUID) -> Annotation? { state.annotations.first { $0.id == id } }

    /// Topmost editable annotation under `point` that satisfies `matching`.
    public func annotation(at point: CGPoint, slop: CGFloat, matching: (Annotation) -> Bool) -> Annotation? {
        state.annotations.last { $0.isEditable && matching($0) && $0.hit(point, slop: slop) }
    }

    /// Swaps in an edited copy of an annotation; `record` stores an undo point first.
    public func replaceAnnotation(_ a: Annotation, record shouldRecord: Bool) {
        guard let i = state.annotations.firstIndex(where: { $0.id == a.id }) else { return }
        if shouldRecord { record() }
        state.annotations[i] = a
    }

    public func removeAnnotation(_ id: UUID) {
        guard state.annotations.contains(where: { $0.id == id }) else { return }
        record()
        state.annotations.removeAll { $0.id == id }
    }

    /// Blanks `rect` to white (baking annotations into the pixels first).
    public func erase(_ rect: CGRect) {
        commitPatch()
        let r = rect.integral.clamped(to: bounds)
        guard r.width >= 1, r.height >= 1 else { return }
        let hole = Patch(image: Renderer.makeContext(width: 1, height: 1).makeImage()!, rect: .zero, vacated: r)
        record()
        state = State(base: Renderer.render(base: state.base, annotations: state.annotations, patch: hole), annotations: [])
    }

    /// Throws the floating block away for good; the area it was lifted from stays white.
    public func deletePatch() {
        guard let p = patch else { return }
        patch = nil
        if let hole = p.vacated { erase(hole) }
    }

    public func nextNumber() -> Int {
        state.annotations.reduce(0) { n, a in
            if case .number = a.kind { return n + 1 }
            return n
        } + 1
    }

    /// Bakes annotations into the pixels, then crops.
    public func crop(to rect: CGRect) {
        commitPatch()
        let r = rect.integral.clamped(to: bounds)
        guard r.width >= 1, r.height >= 1, let cropped = rendered().cropping(to: r) else { return }
        record()
        state = State(base: cropped, annotations: [])
    }

    // MARK: - Floating patch

    public func beginPatch(image: CGImage, rect: CGRect) {
        commitPatch()
        patch = Patch(image: image, rect: rect)
    }

    /// Lifts `rect` off the picture as a floating patch and leaves white behind (cut semantics).
    @discardableResult
    public func liftSelection(_ rect: CGRect) -> Bool {
        commitPatch()
        let r = rect.integral.clamped(to: bounds)
        guard r.width >= 1, r.height >= 1, let img = copyRegion(r) else { return false }
        patch = Patch(image: img, rect: r, vacated: r)
        return true
    }

    /// Centres a patch on `point`, keeping it inside the canvas where possible.
    /// A picture larger than the canvas is scaled down to fit so its handles stay reachable.
    public func paste(_ image: CGImage, centeredAt point: CGPoint) {
        var w = CGFloat(image.width), h = CGFloat(image.height)
        let fit = min(1, size.width / w, size.height / h)
        w = max(1, (w * fit).rounded()); h = max(1, (h * fit).rounded())
        var r = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
        beginPatch(image: image, rect: r.integral)
    }

    public func movePatch(by delta: CGSize) {
        guard patch != nil else { return }
        patch!.rect = patch!.rect.offsetBy(dx: delta.width, dy: delta.height)
    }

    public func setPatchRect(_ rect: CGRect) {
        patch?.rect = rect
    }

    public func commitPatch() {
        guard var patch else { return }
        self.patch = nil
        record()
        var base = state.base
        var annotations = state.annotations
        // a block dragged past the edge grows the canvas (new area is white)
        let target = bounds.union(patch.rect.integral)
        if target != bounds {
            let shift = CGPoint(x: -target.minX, y: -target.minY)
            base = Self.expand(base, to: target.size, shifted: shift)
            annotations = annotations.map { var a = $0; a.move(by: CGSize(width: shift.x, height: shift.y)); return a }
            patch.rect = patch.rect.offsetBy(dx: shift.x, dy: shift.y)
            patch.vacated = patch.vacated?.offsetBy(dx: shift.x, dy: shift.y)
        }
        state = State(base: Renderer.render(base: base, annotations: annotations, patch: patch), annotations: [])
    }

    private static func expand(_ image: CGImage, to size: CGSize, shifted: CGPoint) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = Renderer.makeContext(width: w, height: h)
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CG origin is bottom-left; `shifted` is top-left based
        ctx.draw(image, in: CGRect(x: shifted.x, y: CGFloat(h) - shifted.y - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()!
    }

    public func cancelPatch() { patch = nil }

    // MARK: - Undo / redo

    public func undo() {
        if patch != nil { patch = nil; return }
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }
}
