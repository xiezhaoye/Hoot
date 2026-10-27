import AppKit
import SwiftUI
import ShotPadCore

/// Draws the document and turns mouse/keyboard input into edits.
/// Image pixels map to view points through `zoom` (points per pixel).
final class CanvasView: NSView, NSTextViewDelegate {
    /// The grey area around the white board.
    static let surround = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
    }

    weak var model: EditorModel?
    private(set) var zoom: CGFloat = 0.5
    private var cache: CGImage?
    private var panOrigin: (mouse: CGPoint, scroll: CGPoint)?

    // interaction state
    private var dragStart: CGPoint?
    private var draftPoints: [CGPoint] = []
    private var draftRect: CGRect?
    private var selection: CGRect? { didSet { model?.documentChanged() } }
    private var cropRect: CGRect? { didSet { model?.documentChanged() } }
    private enum PatchDrag { case move(grab: CGPoint, origin: CGRect), resize(Handle, CGRect) }
    private var patchDrag: PatchDrag?
    private var patchDragRecorded = false
    private var selectionDrag: PatchDrag?
    /// Edge / interior drag on a raw selection: the content is lifted into a block on the first real movement.
    private var pendingLift: (handle: Handle?, rect: CGRect)?
    private var textField: NSTextView?
    private var editRect: CGRect = .zero         // text box while typing, image pixels
    private var editFont: CGFloat = 28
    private var editManualWidth: CGFloat?       // box width the user dragged to (text area, excluding padding)
    private var editWrapWidth: CGFloat?         // set while the text is squeezed into several lines
    private enum EditDrag { case move(grab: CGPoint, origin: CGRect), resize(Handle, CGRect, font: CGFloat) }
    private var editDrag: EditDrag?
    private let textPad: CGFloat = 4
    private var editingText: Annotation?          // existing text being re-typed
    private var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            // back to "drawing": the next shape uses this tool's last edited style, not the style of whatever was selected
            if selectedID == nil, let m = model { m.restoreStyle(for: m.tool) }
            model?.documentChanged()
        }
    }
    private struct AnnotationDrag {
        var handle: AnnotationHandle?
        var original: Annotation
        var grab: CGPoint
        var moved = false
        var recorded = false
    }
    private var annDrag: AnnotationDrag?
    private var styleRecordedID: UUID?
    var suppressStyle = false

    /// Free space around the picture, so floating blocks can be parked outside it (the canvas grows when they are confirmed).
    private let inset: CGFloat = 240
    private var hoverPoint: CGPoint?

    private var selectionColor: NSColor { AppSettings.shared.selectionNSColor }

    override var isFlipped: Bool { true }
    // while typing, clicks on the box handles must not steal focus from the field (that would end editing)
    override var acceptsFirstResponder: Bool { textField == nil }

    var doc: EditorDocument? { model?.doc }

    /// Which annotation kind each drawing tool can pick up again.
    private func matches(_ a: Annotation, _ tool: Tool) -> Bool {
        switch (a.kind, tool) {
        case (.pen, .pen), (.highlighter, .highlighter), (_, .hand), (_, .select): return true
        case (.rect, .rect), (.ellipse, .ellipse), (.line, .line), (.arrow, .arrow), (.text, .text), (.number, .number): return true
        default: return false
        }
    }

    /// The selected annotation, only while the matching tool is active.
    var selectedAnnotation: Annotation? {
        guard let id = selectedID, let tool = model?.tool, let a = doc?.annotation(id), matches(a, tool) else { return nil }
        return a
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        if model?.tool == .select || model?.tool == .crop { needsDisplay = true }
        updateCursor(at: hoverPoint ?? .zero)
    }

    // MARK: Zoom

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Changes the zoom keeping the image point under `anchor` (view coordinates) where it is on screen.
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        guard doc != nil, let clip = enclosingScrollView?.contentView else { return }
        model?.zoomFitted = false
        commitText()
        let z = min(max(newZoom, 0.05 / backing), 8 / backing)
        guard abs(z - zoom) > 1e-6 else { return }
        let pivot = anchor ?? convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), from: clip)
        let img = imagePoint(viewPoint: pivot)
        let rel = CGPoint(x: pivot.x - clip.bounds.minX, y: pivot.y - clip.bounds.minY)
        zoom = z
        let doc = self.doc!
        frame.size = CGSize(width: doc.size.width * zoom + inset * 2, height: doc.size.height * zoom + inset * 2)
        let np = viewPoint(img)
        clip.scroll(to: NSPoint(x: np.x - rel.x, y: np.y - rel.y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        model?.zoomPercent = Int((zoom * backing * 100).rounded())
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func setZoomPercent(_ p: Int) { setZoom(CGFloat(p) / 100 / backing) }

    func zoomToFit() {
        guard let doc, let clip = enclosingScrollView?.contentView else { return }
        let w = (clip.bounds.width - 24) / max(doc.size.width, 1), h = (clip.bounds.height - 24) / max(doc.size.height, 1)
        setZoom(min(w, h, 1 / backing))
        clip.scroll(to: NSPoint(x: inset - 12, y: inset - 12))
        enclosingScrollView?.reflectScrolledClipView(clip)
        model?.zoomFitted = true
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    func finishTextEditing() { commitText() }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    func attach(_ model: EditorModel) {
        self.model = model
        window?.makeFirstResponder(self)
        reload(resetScroll: true)
        restoreViewport()
    }

    func restoreViewport() {
        guard let saved = model?.restoredView else { return }
        model?.restoredView = nil; setZoomPercent(saved.zoom)
        if let origin = saved.origin, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: origin); enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Re-renders after the document (or its identity) changed.
    /// `keepView` leaves zoom and scroll position alone (undo / redo), otherwise zoom returns to 100%.
    func reload(resetScroll: Bool = false, keepView: Bool = false) {
        guard doc != nil else { return }
        commitText()
        selection = nil; cropRect = nil; draftRect = nil; draftPoints = []; selectedID = nil; annDrag = nil
        if !keepView {
            zoom = 1 / backing
            model?.zoomPercent = 100
            model?.zoomFitted = false
        }
        refresh()
        if resetScroll, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: inset - 12, y: inset - 12))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func refresh() {
        guard let doc else { return }
        cache = doc.composite()
        let size = CGSize(width: doc.size.width * zoom + inset * 2, height: doc.size.height * zoom + inset * 2)
        if frame.size != size { frame.size = size }
        needsDisplay = true
        model?.documentChanged()
    }

    // MARK: Coordinates

    private func imagePoint(viewPoint p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - inset) / zoom, y: (p.y - inset) / zoom)
    }

    private func imagePoint(_ e: NSEvent) -> CGPoint { imagePoint(viewPoint: convert(e.locationInWindow, from: nil)) }

    private func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + inset, y: p.y * zoom + inset) }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + inset, y: r.minY * zoom + inset, width: r.width * zoom, height: r.height * zoom)
    }

    private var mouseInImage: CGPoint {
        guard let window else { return .zero }
        return imagePoint(viewPoint: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let doc else { return }
        Self.surround.setFill()
        dirtyRect.fill()
        let imageRect = viewRect(doc.bounds)
        if let cache {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10, color: NSColor.black.withAlphaComponent(0.16).cgColor)
            NSColor.white.setFill()
            imageRect.fill()      // white under the picture, so transparent pixels read as white paper
            ctx.interpolationQuality = zoom < 1 ? .high : .none
            Renderer.drawImage(ctx, cache, in: imageRect)
            ctx.restoreGState()
        }
        for patch in doc.patches {
            ctx.saveGState()
            // Interior is already composited in object order; paint only overflow here.
            ctx.addRect(visibleRect); ctx.addRect(imageRect); ctx.clip(using: .evenOdd)
            ctx.interpolationQuality = .none
            if let hole = patch.vacated {
                NSColor.white.setFill()
                viewRect(hole).fill()
            }
            Renderer.drawImage(ctx, patch.image, in: viewRect(patch.rect))
            ctx.restoreGState()
            if patch.id == doc.selectedPatchID {
                outline(viewRect(patch.rect), color: selectionColor, dashed: true)
                drawHandles(viewRect(patch.rect))
            }
        }
        if let s = selection {
            outline(viewRect(s), color: selectionColor, dashed: true)
            if model?.tool == .select, doc.patch == nil { drawHandles(viewRect(s)) }
        }
        if let c = cropRect { outline(viewRect(c), color: selectionColor, dashed: true) }
        if patchDrag != nil, let patch = doc.patch {
            // alignment lines: two horizontal and two vertical, along the edges of the block being moved
            let r = viewRect(patch.rect), v = visibleRect
            let path = NSBezierPath()
            path.lineWidth = 1
            for y in [r.minY, r.maxY] { path.move(to: CGPoint(x: v.minX, y: y)); path.line(to: CGPoint(x: v.maxX, y: y)) }
            for x in [r.minX, r.maxX] { path.move(to: CGPoint(x: x, y: v.minY)); path.line(to: CGPoint(x: x, y: v.maxY)) }
            selectionColor.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }
        if let d = draftRect { outline(viewRect(d), color: model?.color.nsColor ?? .red, dashed: false) }
        if let tool = model?.tool, let m = model, dragStart != nil {
            ctx.saveGState()
            ctx.translateBy(x: inset, y: inset)
            ctx.scaleBy(x: zoom, y: zoom)
            switch tool {
            case .pen: Renderer.draw(m.applyAppearance(to: Annotation(.pen(draftPoints), color: m.color.rgba, lineWidth: m.lineWidth)), in: ctx)
            case .highlighter: Renderer.draw(m.applyAppearance(to: Annotation(.highlighter(draftPoints), color: m.color.rgba, lineWidth: m.lineWidth)), in: ctx)
            case .rect, .ellipse, .line, .arrow:
                if let s = dragStart, let e = draftPoints.last {
                    let kind: Annotation.Kind = tool == .rect ? .rect(.spanning(s, e)) : tool == .ellipse ? .ellipse(.spanning(s, e))
                        : tool == .line ? .line(s, e) : .arrow(s, e)
                    Renderer.draw(m.applyAppearance(to: Annotation(kind, color: m.color.rgba, lineWidth: m.lineWidth)), in: ctx)
                }
            default: break
            }
            ctx.restoreGState()
        }
        if let tool = model?.tool, tool == .select || tool == .crop, let h = hoverPoint {
            // full-width / full-height guide lines through the cursor
            let line = selectionColor.withAlphaComponent(0.55)
            line.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: CGPoint(x: visibleRect.minX, y: h.y)); path.line(to: CGPoint(x: visibleRect.maxX, y: h.y))
            path.move(to: CGPoint(x: h.x, y: visibleRect.minY)); path.line(to: CGPoint(x: h.x, y: visibleRect.maxY))
            path.stroke()
        }
        if let tool = model?.tool, tool == .select || tool == .crop, let h = hoverPoint, let cache {
            let px = imagePoint(viewPoint: h)
            var info = "\(Int(px.x)), \(Int(px.y))"
            if let r = tool == .select ? selection : cropRect { info += "   \(Int(r.width))×\(Int(r.height))" }
            Magnifier.draw(in: ctx, image: cache, pixel: px, cursor: h, bounds: visibleRect, info: info)
        }
        if textField != nil {
            outline(viewRect(editRect), color: selectionColor, dashed: false)
            // only the vertical sides stretch the box; top and bottom just move it
            let r = viewRect(editRect)
            for pt in [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] {
                let box = CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)
                NSColor.white.setFill(); box.fill()
                selectionColor.setStroke(); NSBezierPath(rect: box).stroke()
            }
        }
        if let a = selectedAnnotation, let b = a.bounds {
            outline(viewRect(b), color: selectionColor, dashed: true)
            for (_, pt) in a.handles {
                let v = viewPoint(pt)
                let r = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
                NSColor.white.setFill(); r.fill()
                selectionColor.setStroke(); NSBezierPath(rect: r).stroke()
            }
        }
    }

    private func drawHandles(_ rect: CGRect) {
        for h in Handle.allCases {
            let p = h.point(in: rect)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); r.fill()
            selectionColor.setStroke(); NSBezierPath(rect: r).stroke()
        }
    }

    private func selectionHandle(at p: CGPoint, in rect: CGRect) -> Handle? {
        Handle.hit(in: rect, at: p, slop: 7 / zoom)
    }

    private func resizeCursor(_ h: Handle) -> NSCursor {
        let pos: NSCursor.FrameResizePosition
        switch h {
        case .topLeft: pos = .topLeft
        case .top: pos = .top
        case .topRight: pos = .topRight
        case .right: pos = .right
        case .bottomRight: pos = .bottomRight
        case .bottom: pos = .bottom
        case .bottomLeft: pos = .bottomLeft
        case .left: pos = .left
        }
        return NSCursor.frameResize(position: pos, directions: .all)
    }

    private enum TextBoxHit { case side(Handle), move }
    /// Left / right edges and the four corners stretch the width; the top and bottom edges (and the rim around the box) move it.
    private func textBoxHit(_ p: CGPoint) -> TextBoxHit? {
        let slop = 8 / zoom
        let tall = editRect.insetBy(dx: 0, dy: -slop)
        if tall.minY...tall.maxY ~= p.y {
            if abs(p.x - editRect.minX) <= slop { return .side(.left) }
            if abs(p.x - editRect.maxX) <= slop { return .side(.right) }
        }
        if editRect.insetBy(dx: -14 / zoom, dy: -14 / zoom).contains(p) { return .move }
        return nil
    }

    /// Cursor follows what a drag would do here: resize on a selection / block edge, move inside it.
    private func updateCursor(at viewPoint: CGPoint) {
        if textField != nil {
            let p = imagePoint(viewPoint: viewPoint)
            switch textBoxHit(p) {
            case .side: NSCursor.resizeLeftRight.set()
            case .move: NSCursor.openHand.set()
            case nil: break
            }
            return
        }
        guard let model, let doc else { return }
        let p = imagePoint(viewPoint: viewPoint)
        if let patch = doc.patch {
            if let h = patch.hitHandle(at: p, slop: 7 / zoom) { resizeCursor(h).set(); return }
            if patch.rect.contains(p) { NSCursor.openHand.set(); return }
        } else if model.tool == .select, let s = selection {
            if let h = selectionHandle(at: p, in: s) {
                resizeCursor(h).set(); return
            }
            if s.contains(p) { NSCursor.openHand.set(); return }
        }
        (model.tool == .hand ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    private func outline(_ r: CGRect, color: NSColor, dashed: Bool) {
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1.5
        if dashed { path.setLineDash([5, 4], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model, let doc else { return }
        let p = imagePoint(event)
        if textField != nil {
            switch textBoxHit(p) {
            case .side(let h): editDrag = .resize(h, editRect, font: editFont); dragStart = p; return
            case .move: editDrag = .move(grab: p, origin: editRect); dragStart = p; return
            case nil: break
            }
            commitText()
        }
        window?.makeFirstResponder(self)
        if model.tool == .hand, doc.patch(at: p, slop: 7 / zoom) == nil, doc.annotation(at: p, slop: 6 / zoom, matching: { _ in true }) == nil,
           let clip = enclosingScrollView?.contentView {
            panOrigin = (event.locationInWindow, clip.bounds.origin)
            NSCursor.closedHand.set()
            return
        }
        // The raw selection owns its border/interior before objects beneath it.
        if model.tool == .select, let s = selection {
            let handle = selectionHandle(at: p, in: s)
            if handle != nil || s.contains(p) {
                // Corners resize the selection frame; edges stretch and the interior moves the selected content itself.
                if let handle, [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle) { selectionDrag = .resize(handle, s) }
                else { pendingLift = (handle, s) }
                dragStart = p; return
            }
        }
        patchDragRecorded = false
        if let block = doc.patch(at: p, slop: 7 / zoom), doc.patchIsAboveAnnotations(block, at: p, slop: 6 / zoom), model.tool == .select || model.tool == .hand || block.id == doc.selectedPatchID {
            doc.selectedPatchID = block.id; selectedID = nil; selection = nil
            if let h = block.hitHandle(at: p, slop: 7 / zoom) { patchDrag = .resize(h, block.rect) }
            else { patchDrag = .move(grab: p, origin: block.rect) }
            dragStart = p; model.documentChanged(); needsDisplay = true; return
        }
        doc.selectedPatchID = nil
        if matchesDrawingTool(model.tool) || model.tool == .hand || model.tool == .select {
            let slop = 6 / zoom
            if let sel = selectedAnnotation, let h = sel.handle(at: p, slop: 7 / zoom) {
                annDrag = AnnotationDrag(handle: h, original: sel, grab: p); dragStart = p; return
            }
            if let a = doc.annotation(at: p, slop: slop, matching: { self.matches($0, model.tool) }) {
                if event.clickCount >= 2, case .text = a.kind { selectedID = a.id; beginText(at: .zero, existing: a); return }
                selectedID = a.id
                loadStyle(from: a)
                annDrag = AnnotationDrag(handle: nil, original: a, grab: p); dragStart = p
                needsDisplay = true
                return
            }
            selectedID = nil
        }
        dragStart = p
        draftPoints = [p]
        switch model.tool {
        case .select:
            selection = nil
        case .text:
            beginText(at: p)
            dragStart = nil
        case .number:
            addAndSelect(Annotation(.number(doc.nextNumber(), center: p, diameter: model.numberDiameter), color: model.color.rgba))
            dragStart = nil
        default: break
        }
        needsDisplay = true
    }

    private func matchesDrawingTool(_ t: Tool) -> Bool {
        t == .pen || t == .highlighter || t == .rect || t == .ellipse || t == .line || t == .arrow || t == .text || t == .number
    }

    override func mouseDragged(with event: NSEvent) {
        if let pan = panOrigin, let clip = enclosingScrollView?.contentView {
            let dx = event.locationInWindow.x - pan.mouse.x, dy = event.locationInWindow.y - pan.mouse.y
            clip.scroll(to: NSPoint(x: pan.scroll.x - dx, y: pan.scroll.y + dy))
            enclosingScrollView?.reflectScrolledClipView(clip)
            return
        }
        guard let model, let doc, let s = dragStart else { return }
        let p = imagePoint(event)
        hoverPoint = convert(event.locationInWindow, from: nil)
        if let drag = editDrag {
            switch drag {
            case .move(let grab, let origin):
                editRect = origin.offsetBy(dx: (p.x - grab.x).rounded(), dy: (p.y - grab.y).rounded())
            case .resize(let h, let original, _):
                let outer = h == .left ? original.maxX - p.x : p.x - original.minX
                editManualWidth = max(40, outer - 2 * textPad)
                layoutTextBox()
                if h == .left { editRect.origin.x = original.maxX - editRect.width }
            }
            syncEditField(); syncLiveText()
            needsDisplay = true
            return
        }
        if var drag = annDrag {
            if !drag.moved && hypot(p.x - drag.grab.x, p.y - drag.grab.y) < 3 / zoom { return }
            drag.moved = true
            var updated: Annotation
            if let h = drag.handle {
                updated = drag.original.dragged(h, to: p)
            } else {
                updated = drag.original
                updated.move(by: CGSize(width: (p.x - drag.grab.x).rounded(), height: (p.y - drag.grab.y).rounded()))
            }
            doc.replaceAnnotation(updated, record: !drag.recorded)
            drag.recorded = true
            annDrag = drag
            rememberNumber(updated)
            refresh()
            return
        }
        if let lift = pendingLift {
            pendingLift = nil
            guard doc.liftSelection(lift.rect), let block = doc.patch else { return }
            selection = nil; selectedID = nil
            patchDragRecorded = true       // the lift already recorded the undo step
            if let h = lift.handle { patchDrag = .resize(h, block.rect) } else { patchDrag = .move(grab: s, origin: block.rect) }
        }
        if let drag = selectionDrag {
            switch drag {
            case .move(let grab, let origin):
                var r = origin.offsetBy(dx: p.x - grab.x, dy: p.y - grab.y)
                r.origin.x = min(max(0, r.minX), max(0, doc.size.width - r.width))
                r.origin.y = min(max(0, r.minY), max(0, doc.size.height - r.height)); selection = r.integral
            case .resize(let h, let original): selection = Patch.resized(original, handle: h, to: p).clamped(to: doc.bounds).integral
            }
            needsDisplay = true; return
        }
        if let drag = patchDrag {
            if !patchDragRecorded { doc.record(); patchDragRecorded = true }
            switch drag {
            case .move(let grab, let origin):
                doc.setPatchRect(origin.offsetBy(dx: (p.x - grab.x).rounded(), dy: (p.y - grab.y).rounded()), record: false)
            case .resize(let h, let original):
                doc.setPatchRect(Patch.resized(original, handle: h, to: CGPoint(x: p.x.rounded(), y: p.y.rounded())), record: false)
            }
            refresh()
            return
        }
        let endpoint = event.modifierFlags.contains(.shift) && (model.tool == .rect || model.tool == .ellipse)
            ? DrawingGeometry.squareEndpoint(from: s, to: p) : p
        draftPoints.append(endpoint)
        let r = CGRect.spanning(s, p).clamped(to: doc.bounds)
        switch model.tool {
        case .select: selection = r
        case .crop: cropRect = r
        case .mosaic, .blur: draftRect = r
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panOrigin != nil { panOrigin = nil; window?.invalidateCursorRects(for: self); return }
        guard let model, let doc, let s = dragStart else { dragStart = nil; return }
        if editDrag != nil {
            editDrag = nil; dragStart = nil
            // only refocus when the field lost focus: re-selecting a field that is being edited would end the edit
            if let f = textField { window?.makeFirstResponder(f) }
            return
        }
        defer { dragStart = nil; patchDrag = nil; selectionDrag = nil; annDrag = nil; editDrag = nil; pendingLift = nil; draftRect = nil; draftPoints = []; needsDisplay = true }
        if annDrag != nil || editDrag != nil { return }
        if patchDrag != nil || selectionDrag != nil || pendingLift != nil { return }
        let point = imagePoint(event)
        let e = event.modifierFlags.contains(.shift) && (model.tool == .rect || model.tool == .ellipse)
            ? DrawingGeometry.squareEndpoint(from: s, to: point) : point
        let r = CGRect.spanning(s, e).clamped(to: doc.bounds)
        let big = abs(e.x - s.x) >= 3 || abs(e.y - s.y) >= 3
        let color = model.color.rgba, w = model.lineWidth
        switch model.tool {
        case .select: if !big { selection = nil } else { selection = r.integral }
        case .crop: if !big { cropRect = nil } else { cropRect = r.integral }
        case .rect where big: addAndSelect(Annotation(.rect(.spanning(s, e)), color: color, lineWidth: w))
        case .ellipse where big: addAndSelect(Annotation(.ellipse(.spanning(s, e)), color: color, lineWidth: w))
        case .line where big: addAndSelect(Annotation(.line(s, e), color: color, lineWidth: w))
        case .arrow where big: addAndSelect(Annotation(.arrow(s, e), color: color, lineWidth: w))
        case .pen: addAndSelect(Annotation(.pen(draftPoints + [e]), color: color, lineWidth: w))
        case .highlighter: addAndSelect(Annotation(.highlighter(draftPoints + [e]), color: color, lineWidth: w))
        case .mosaic where big: doc.add(Annotation(.mosaic(r, block: max(6, Int(w) * 3)))); refresh()
        case .blur where big: doc.add(Annotation(.blur(r, radius: max(4, Double(w) * 3)))); refresh()
        default: break
        }
    }

    // MARK: Text tool

    private func addAndSelect(_ a: Annotation) {
        let a = model?.applyAppearance(to: a) ?? a
        AppSettings.shared.noteUsed(a.color)
        doc?.add(a)
        selectedID = a.id
        refresh()
    }

    private func beginText(at p: CGPoint, existing: Annotation? = nil) {
        guard let model, let doc else { return }
        var a = existing ?? model.applyAppearance(to: Annotation(.text("", origin: p, fontSize: model.fontSize), color: model.color.rgba))
        if existing != nil { doc.record() }
        if existing == nil { a.textAreaWidth = max(240, model.fontSize * 8); doc.add(a) }
        guard case .text(let text, let origin, let size) = a.kind else { return }
        loadStyle(from: a)
        editingText = a; selectedID = a.id; editFont = size
        editManualWidth = a.boxWidth ?? (a.textAreaWidth > 240 ? a.textAreaWidth : nil); editWrapWidth = a.boxWidth
        doc.hiddenAnnotationID = a.id
        editRect = CGRect(x: origin.x - textPad, y: origin.y - textPad, width: a.bounds!.width + 2 * textPad, height: a.bounds!.height + 2 * textPad)
        let field = NSTextView(frame: .zero)
        field.isRichText = false; field.importsGraphics = false; field.allowsUndo = true
        field.drawsBackground = true; field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = false
        field.textContainer?.containerSize = NSSize(width: 10_000_000, height: 10_000_000)
        field.isHorizontallyResizable = true; field.isVerticallyResizable = true
        field.string = text; field.delegate = self
        field.textColor = a.color.nsColor; field.alphaValue = a.opacity
        addSubview(field); textField = field; syncEditField(); refresh()
        window?.makeFirstResponder(field)
    }

    private func syncEditField() {
        guard let field = textField else { return }
        // The outer border and the strip above it belong to CanvasView, so they remain draggable.
        field.frame = viewRect(editRect.insetBy(dx: textPad, dy: textPad))
        field.font = .systemFont(ofSize: editFont * zoom, weight: .medium)
        let wrapped = editWrapWidth != nil
        field.isHorizontallyResizable = !wrapped
        field.textContainer?.widthTracksTextView = wrapped
        field.textContainer?.containerSize = NSSize(width: wrapped ? field.frame.width : 10_000_000, height: 10_000_000)
    }

    /// Keep the document current even while its native text editor owns focus.
    private func syncLiveText() {
        guard let field = textField, var a = editingText, let doc else { return }
        a.kind = .text(field.string, origin: CGPoint(x: editRect.minX + textPad, y: editRect.minY + textPad), fontSize: editFont)
        a.boxWidth = editWrapWidth; a.textAreaWidth = max(40, editRect.width - 2 * textPad)
        editingText = a; doc.replaceAnnotation(a, record: false); model?.documentChanged()
    }

    func commitText() {
        guard let field = textField, let doc else { return }
        syncLiveText(); textField = nil; field.delegate = nil; field.removeFromSuperview()
        doc.hiddenAnnotationID = nil
        if let a = editingText {
            if field.string.isEmpty { doc.removeAnnotation(a.id); selectedID = nil }
            else { selectedID = a.id }
        }
        editingText = nil; editManualWidth = nil; editWrapWidth = nil; refresh()
    }

    func textDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        layoutTextBox()
        syncEditField(); syncLiveText(); needsDisplay = true
    }

    /// Box width follows the text (with a blank tail) until the user drags it; a dragged width keeps the text on one line
    /// while it fits and squeezes it into several lines once it does not.
    private func layoutTextBox() {
        guard let field = textField else { return }
        let natural = Renderer.textSize(field.string, fontSize: editFont).width + 16
        var inner = max(240, natural)
        var wrap: CGFloat?
        if let manual = editManualWidth {
            inner = manual
            if natural > manual { wrap = manual }
        }
        let height = wrap.map { Renderer.textSize(field.string, fontSize: editFont, width: $0).height }
            ?? Renderer.textSize(field.string, fontSize: editFont).height
        editWrapWidth = wrap
        editRect.size = CGSize(width: inner + 2 * textPad, height: max(editFont * 1.25, height) + 2 * textPad)
        syncEditField(); syncLiveText(); needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { commitText(); window?.makeFirstResponder(self); return true }
        // NSTextView handles Return/newline, Backspace, IME and text selection natively.
        return false
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" {
            model?.saveAs(); return true
        }
        // Let the new search field (and native text inputs) handle their own editing shortcuts.
        // Toolbar focus must still allow the existing canvas shortcuts to work.
        guard !(window?.firstResponder is NSTextView), !(window?.firstResponder is NSTextField), textField == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "x": cutSelection(); return true
        case "c": copySelection(); return true
        case "v": pasteImage(); return true
        case "s": model?.saveAs(); return true
        case "f" where event.modifierFlags.contains(.shift): model?.fixAll(); return true
        case "a": doc?.selectedPatchID = nil; selectedID = nil; selection = doc?.bounds; model?.tool = .select; needsDisplay = true; return true
        case "z": event.modifierFlags.contains(.shift) ? redo() : undo(); return true
        case "=", "+": setZoom(zoom * 1.25); return true
        case "-": setZoom(zoom / 1.25); return true
        case "0": setZoomPercent(100); return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let doc else { return }
        switch event.keyCode {
        case 36, 76: // return
            if let c = cropRect { doc.crop(to: c); reload() }
        case 51, 117: // delete / forward delete
            if let a = selectedAnnotation { doc.removeAnnotation(a.id); selectedID = nil; refresh() }
            else if doc.patch != nil { doc.deletePatch(); refresh() }
            else if let s = selection { doc.erase(s); selection = nil; refresh() }
            else if cropRect != nil, model?.tool == .crop { cropRect = nil; needsDisplay = true }
        case 18, 19, 83, 84: // 1 / 2 (main row and keypad)
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if !(plain && adjustStrength(up: event.keyCode == 19 || event.keyCode == 84)) { super.keyDown(with: event) }
        case 53: // esc
            if selectedID != nil { selectedID = nil }
            else if doc.patch != nil { doc.cancelPatch(); model?.documentChanged() }
            cropRect = nil; selection = nil; model?.tool = .hand
            window?.invalidateCursorRects(for: self); needsDisplay = true
        case 123, 124, 125, 126:
            guard let patch = doc.patch else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let d: CGSize = event.keyCode == 123 ? CGSize(width: -step, height: 0) : event.keyCode == 124 ? CGSize(width: step, height: 0)
                : event.keyCode == 125 ? CGSize(width: 0, height: step) : CGSize(width: 0, height: -step)
            doc.setPatchRect(patch.rect.offsetBy(dx: d.width, dy: d.height)); refresh()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Edit commands

    var selectionRect: CGRect? { selection }
    var activeSelectionRect: CGRect? { model?.tool == .crop ? cropRect : selection }

    func copySelection() {
        guard let doc else { return }
        if let s = selection, let img = doc.copyRegion(s) { Clipboard.write(img); model?.status = "已复制选区 \(img.width)×\(img.height)"; return }
        if let patch = doc.patch { Clipboard.write(patch.rasterized()); model?.status = "已复制区块"; return }
        Clipboard.write(doc.flattened()); model?.status = "已复制整张图片"
    }

    func cutSelection() {
        guard let doc else { return }
        if let patch = doc.patch {
            Clipboard.write(patch.rasterized()); doc.deletePatch(); refresh(); model?.status = "已剪切浮动块"
        } else if let s = selection, let img = doc.copyRegion(s) {
            Clipboard.write(img); doc.erase(s); selection = nil; refresh(); model?.status = "已剪切选区 \(img.width)×\(img.height)，可粘贴到本图或其他历史截图"
        } else { NSSound.beep() }
    }

    // responder-chain entry points, so the Edit menu and the context menu work too
    @objc(undo:) func undoAction(_ sender: Any?) { undo() }
    @objc(redo:) func redoAction(_ sender: Any?) { redo() }
    @objc(cut:) func cutAction(_ sender: Any?) { cutSelection() }
    @objc(copy:) func copyAction(_ sender: Any?) { copySelection() }
    @objc(paste:) func pasteAction(_ sender: Any?) { pasteImage() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "剪切", action: #selector(cutAction(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "复制", action: #selector(copyAction(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "粘贴", action: #selector(pasteAction(_:)), keyEquivalent: "").target = self
        return m
    }

    func pasteImage() {
        guard let doc, let img = Clipboard.readImage() else { model?.status = "剪贴板里没有图片"; return }
        let inside = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        let anchor = inside ? mouseInImage : CGPoint(x: doc.size.width / 2, y: doc.size.height / 2)
        selection = nil
        model?.tool = .select
        doc.paste(img, centeredAt: anchor)
        selectedID = nil; refresh()
        model?.status = "已粘贴：可随时移动、缩放；保存或固定全部时合并"
    }

    func undo() { commitText(); doc?.undo(); reload(keepView: true) }
    func redo() { commitText(); doc?.redo(); reload(keepView: true) }

    func finishPatch() { commitText(); doc?.flattenAll(); selectedID = nil; selection = nil; refresh() }

    // MARK: Styling the selected annotation

    enum StyleChange { case color, width, font, appearance }

    /// Tool settings changed: apply to the selected annotation too.
    func styleChanged(_ change: StyleChange) {
        guard !suppressStyle, let m = model, let doc else { return }
        if textField != nil {
            if change == .font { editFont = m.fontSize; textDidChange(Notification(name: NSText.didChangeNotification)) }
            if var a = editingText {
                if change == .color { a.color = m.color.rgba; textField?.textColor = a.color.nsColor }
                if change == .appearance { a = m.applyAppearance(to: a); textField?.alphaValue = a.opacity }
                editingText = a; syncLiveText()
            }
            m.rememberStyle(for: .text)
            return
        }
        guard var a = selectedAnnotation else { return }
        switch change {
        case .color: a.color = m.color.rgba
        case .width:
            switch a.kind {
            case .text, .number: return
            case .mosaic(let r, _): a.kind = .mosaic(r, block: max(6, Int(m.lineWidth) * 3))
            case .blur(let r, _): a.kind = .blur(r, radius: max(4, Double(m.lineWidth) * 3))
            default: a.lineWidth = m.lineWidth
            }
        case .font:
            guard case .text(let s, let o, _) = a.kind else { return }
            a.kind = .text(s, origin: o, fontSize: m.fontSize)
        case .appearance: a = m.applyAppearance(to: a)
        }
        doc.replaceAnnotation(a, record: true)
        styleRecordedID = a.id
        m.rememberStyle(for: Self.tool(of: a))
        rememberNumber(a); refresh()
    }

    private static func tool(of a: Annotation) -> Tool {
        switch a.kind {
        case .rect: .rect; case .ellipse: .ellipse; case .line: .line; case .arrow: .arrow; case .pen: .pen
        case .highlighter: .highlighter; case .mosaic: .mosaic; case .blur: .blur; case .text, .textBox: .text; case .number: .number
        }
    }

    /// Keys 1 / 2: thinner / thicker stroke, smaller / larger text, weaker / stronger mosaic or blur.
    private func adjustStrength(up: Bool) -> Bool {
        guard let m = model else { return false }
        let target = selectedAnnotation.map(Self.tool(of:)) ?? m.tool
        switch target {
        case .text:
            m.fontSize = min(200, max(8, m.fontSize + (up ? 2 : -2)))
        case .rect, .ellipse, .line, .arrow, .pen, .highlighter, .mosaic, .blur:
            m.lineWidth = min(16, max(1, m.lineWidth + (up ? 1 : -1)))
        default: return false
        }
        m.status = target == .text ? "字号 \(Int(m.fontSize))" : (target == .mosaic || target == .blur ? "强度 \(Int(m.lineWidth))" : "描边 \(Int(m.lineWidth)) px")
        return true
    }

    private func loadStyle(from a: Annotation) {
        guard let m = model else { return }
        suppressStyle = true
        m.colorValue = Color(.sRGB, red: a.color.r, green: a.color.g, blue: a.color.b, opacity: a.color.a)
        m.fill = a.fill; m.opacity = a.opacity; m.cornerRadius = a.cornerRadius; m.shadow = a.shadow
        switch a.kind {
        case .text(_, _, let fs): m.fontSize = fs
        case .number(_, _, let diameter): m.numberDiameter = diameter
        case .mosaic(_, let block): m.lineWidth = CGFloat(max(1, block / 3))
        case .blur(_, let radius): m.lineWidth = CGFloat(max(1, Int(radius / 3)))
        default: m.lineWidth = a.lineWidth
        }
        suppressStyle = false
        styleRecordedID = nil
        m.documentChanged()
    }

    func setSelectedFrame(_ frame: CGRect) {
        guard let annotation = selectedAnnotation else { return }
        let updated = annotation.settingFrame(frame)
        doc?.replaceAnnotation(updated, record: true)
        if textField != nil, case .text(_, let origin, let font) = updated.kind, let b = updated.bounds {
            editingText = updated; editFont = font
            editRect = CGRect(x: origin.x - textPad, y: origin.y - textPad, width: b.width + 2 * textPad, height: b.height + 2 * textPad)
            syncEditField(); syncLiveText()
        }
        styleRecordedID = nil
        rememberNumber(updated); refresh()
        loadStyle(from: updated)
    }

    func reorderSelected(toFront: Bool) {
        guard let annotation = selectedAnnotation else { return }
        doc?.reorderAnnotation(annotation.id, toFront: toFront)
        styleRecordedID = nil
        refresh()
    }

    private func rememberNumber(_ a: Annotation) {
        guard case .number(_, _, let diameter) = a.kind, let m = model else { return }
        m.numberDiameter = diameter
    }
    func cancelPatch() { doc?.deletePatch(); refresh() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: model?.tool == .hand ? .openHand : .crosshair) }
}
