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
    public func rendered() -> CGImage { Renderer.render(base: state.base, annotations: state.annotations) }

    /// Everything, including a patch that has not been committed yet.
    public func flattened() -> CGImage { Renderer.render(base: state.base, annotations: state.annotations, patch: patch) }

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

    /// Centres a patch on `point`, keeping it inside the canvas where possible.
    public func paste(_ image: CGImage, centeredAt point: CGPoint) {
        var r = CGRect(x: point.x - CGFloat(image.width) / 2, y: point.y - CGFloat(image.height) / 2,
                       width: CGFloat(image.width), height: CGFloat(image.height))
        r.origin.x = max(0, min(r.origin.x, size.width - r.width))
        r.origin.y = max(0, min(r.origin.y, size.height - r.height))
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
        guard let patch else { return }
        let merged = Renderer.render(base: state.base, annotations: state.annotations, patch: patch)
        self.patch = nil
        record()
        state = State(base: merged, annotations: [])
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
