import AppKit
import SwiftUI
import ShotPadCore

/// Draws the document and turns mouse/keyboard input into edits.
/// Image pixels map to view points through `zoom` (points per pixel).
final class CanvasView: NSView, NSTextFieldDelegate {
    weak var model: EditorModel?
    private(set) var zoom: CGFloat = 0.5
    private var cache: CGImage?

    // interaction state
    private var dragStart: CGPoint?
    private var draftPoints: [CGPoint] = []
    private var draftRect: CGRect?
    private var selection: CGRect?
    private var cropRect: CGRect?
    private enum PatchDrag { case move(grab: CGPoint, origin: CGRect), resize(Handle, CGRect) }
    private var patchDrag: PatchDrag?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var editingText: Annotation?          // existing text being re-typed
    private var selectedID: UUID?
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
    private var confirmButton: NSButton?
    private var lastHadPatch = false

    private var selectionColor: NSColor { AppSettings.shared.selectionNSColor }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var doc: EditorDocument? { model?.doc }

    /// Which annotation kind each drawing tool can pick up again.
    private func matches(_ a: Annotation, _ tool: Tool) -> Bool {
        switch (a.kind, tool) {
        case (.rect, .rect), (.ellipse, .ellipse), (.line, .line), (.arrow, .arrow), (.text, .text), (.number, .number): return true
        default: return false
        }
    }

    /// The selected annotation, only while the matching tool is active.
    private var selectedAnnotation: Annotation? {
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
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    func attach(_ model: EditorModel) {
        self.model = model
        window?.makeFirstResponder(self)
        reload(resetScroll: true)
    }

    /// Re-renders after the document (or its identity) changed.
    func reload(resetScroll: Bool = false) {
        guard doc != nil else { return }
        commitText()
        selection = nil; cropRect = nil; draftRect = nil; draftPoints = []; selectedID = nil; annDrag = nil
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        zoom = 1 / scale
        refresh()
        if resetScroll, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: inset - 12, y: inset - 12))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func refresh() {
        guard let doc else { return }
        cache = doc.rendered()
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
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        let imageRect = viewRect(doc.bounds)
        if let cache {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.interpolationQuality = zoom < 1 ? .high : .none
            Renderer.drawImage(ctx, cache, in: imageRect)
            ctx.restoreGState()
        }
        if let patch = doc.patch {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            if let hole = patch.vacated {
                NSColor.white.setFill()
                viewRect(hole).fill()
            }
            Renderer.drawImage(ctx, patch.image, in: viewRect(patch.rect))
            ctx.restoreGState()
            outline(viewRect(patch.rect), color: selectionColor, dashed: true)
            drawHandles(viewRect(patch.rect))
        }
        if let s = selection {
            outline(viewRect(s), color: selectionColor, dashed: true)
            if model?.tool == .select, doc.patch == nil { drawHandles(viewRect(s)) }
        }
        if let c = cropRect { outline(viewRect(c), color: selectionColor, dashed: true) }
        if let d = draftRect { outline(viewRect(d), color: model?.color.nsColor ?? .red, dashed: false) }
        if let tool = model?.tool, let m = model, dragStart != nil {
            ctx.saveGState()
            ctx.translateBy(x: inset, y: inset)
            ctx.scaleBy(x: zoom, y: zoom)
            switch tool {
            case .pen: Renderer.draw(Annotation(.pen(draftPoints), color: m.color.rgba, lineWidth: m.lineWidth), in: ctx)
            case .highlighter: Renderer.draw(Annotation(.highlighter(draftPoints), color: m.color.rgba, lineWidth: m.lineWidth), in: ctx)
            case .rect, .ellipse, .line, .arrow:
                if let s = dragStart, let e = draftPoints.last {
                    let kind: Annotation.Kind = tool == .rect ? .rect(.spanning(s, e)) : tool == .ellipse ? .ellipse(.spanning(s, e))
                        : tool == .line ? .line(s, e) : .arrow(s, e)
                    Renderer.draw(Annotation(kind, color: m.color.rgba, lineWidth: m.lineWidth), in: ctx)
                }
            default: break
            }
            ctx.restoreGState()
        }
        if let tool = model?.tool, tool == .select || tool == .crop, let h = hoverPoint, let cache {
            let px = imagePoint(viewPoint: h)
            var info = "\(Int(px.x)), \(Int(px.y))"
            if let r = tool == .select ? selection : cropRect { info += "   \(Int(r.width))×\(Int(r.height))" }
            Magnifier.draw(in: ctx, image: cache, pixel: px, cursor: h, bounds: visibleRect, info: info)
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
        DispatchQueue.main.async { [weak self] in self?.syncPatchUI() }
    }

    /// Keeps the confirm button and the toolbar in step with the floating block.
    private func syncPatchUI() {
        let has = doc?.patch != nil
        if has != lastHadPatch { lastHadPatch = has; model?.documentChanged() }
        guard let patch = doc?.patch else { confirmButton?.removeFromSuperview(); confirmButton = nil; return }
        let b: NSButton
        if let existing = confirmButton { b = existing } else {
            b = NSButton(title: "确认 ⏎", target: self, action: #selector(confirmPatch))
            b.bezelStyle = .rounded; b.controlSize = .small; b.bezelColor = .controlAccentColor
            b.sizeToFit()
            addSubview(b)
            confirmButton = b
        }
        let r = viewRect(patch.rect)
        var o = CGPoint(x: r.maxX - b.frame.width, y: r.maxY + 8)
        if o.y + b.frame.height > frame.height { o.y = r.maxY - b.frame.height - 8 }
        o.x = max(0, o.x)
        if b.frame.origin != o { b.setFrameOrigin(o) }
    }

    @objc private func confirmPatch() { finishPatch() }

    private func drawHandles(_ rect: CGRect) {
        for h in Handle.allCases {
            let p = h.point(in: rect)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); r.fill()
            selectionColor.setStroke(); NSBezierPath(rect: r).stroke()
        }
    }

    private func selectionHandle(at p: CGPoint, in rect: CGRect) -> Handle? {
        let slop = 7 / zoom
        return Handle.allCases.first { h in
            let q = h.point(in: rect)
            return abs(q.x - p.x) <= slop && abs(q.y - p.y) <= slop
        }
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
        window?.makeFirstResponder(self)
        commitText()
        let p = imagePoint(event)
        // a floating block can be resized from its handles whatever tool is active
        if let patch = doc.patch, let h = patch.hitHandle(at: p, slop: 7 / zoom) {
            patchDrag = .resize(h, patch.rect); dragStart = p; return
        }
        if matchesDrawingTool(model.tool) {
            let slop = 6 / zoom
            if let sel = selectedAnnotation, let h = sel.handle(at: p, slop: 7 / zoom) {
                annDrag = AnnotationDrag(handle: h, original: sel, grab: p); dragStart = p; return
            }
            if let a = doc.annotation(at: p, slop: slop, matching: { self.matches($0, model.tool) }) {
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
            if let patch = doc.patch, patch.rect.contains(p) {
                patchDrag = .move(grab: p, origin: patch.rect); return
            } else if doc.patch == nil, let s = selection {
                // grabbing the selection (inside or on a handle) lifts it off the picture, leaving white behind
                let handle = selectionHandle(at: p, in: s)
                if (handle != nil || s.contains(p)), doc.liftSelection(s), let patch = doc.patch {
                    selection = nil
                    patchDrag = handle.map { .resize($0, patch.rect) } ?? .move(grab: p, origin: patch.rect)
                    needsDisplay = true
                    return
                }
            }
            selection = nil
        case .text:
            beginText(at: p)
            dragStart = nil
        case .number:
            let a = Annotation(.number(doc.nextNumber(), center: p, diameter: max(24, model.lineWidth * 7)), color: model.color.rgba)
            doc.add(a)
            selectedID = a.id
            refresh()
            dragStart = nil
        default: break
        }
        needsDisplay = true
    }

    private func matchesDrawingTool(_ t: Tool) -> Bool {
        t == .rect || t == .ellipse || t == .line || t == .arrow || t == .text || t == .number
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let doc, let s = dragStart else { return }
        let p = imagePoint(event)
        hoverPoint = convert(event.locationInWindow, from: nil)
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
            refresh()
            return
        }
        if let drag = patchDrag {
            switch drag {
            case .move(let grab, let origin):
                doc.setPatchRect(origin.offsetBy(dx: (p.x - grab.x).rounded(), dy: (p.y - grab.y).rounded()))
            case .resize(let h, let original):
                doc.setPatchRect(Patch.resized(original, handle: h, to: CGPoint(x: p.x.rounded(), y: p.y.rounded())))
            }
            needsDisplay = true
            return
        }
        draftPoints.append(p)
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
        guard let model, let doc, let s = dragStart else { dragStart = nil; return }
        defer { dragStart = nil; patchDrag = nil; annDrag = nil; draftRect = nil; draftPoints = []; needsDisplay = true }
        if let drag = annDrag {
            // a plain click on text goes back into editing
            if !drag.moved, drag.handle == nil, case .text = drag.original.kind { beginText(at: drag.original.bounds?.origin ?? s, existing: drag.original) }
            return
        }
        if patchDrag != nil { return }
        let e = imagePoint(event)
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
        case .pen: doc.add(Annotation(.pen(draftPoints + [e]), color: color, lineWidth: w)); refresh()
        case .highlighter: doc.add(Annotation(.highlighter(draftPoints + [e]), color: color, lineWidth: w)); refresh()
        case .mosaic where big: doc.add(Annotation(.mosaic(r, block: max(6, Int(w) * 3)))); refresh()
        case .blur where big: doc.add(Annotation(.blur(r, radius: max(4, Double(w) * 3)))); refresh()
        default: break
        }
    }

    // MARK: Text tool

    private func addAndSelect(_ a: Annotation) {
        doc?.add(a)
        selectedID = a.id
        refresh()
    }

    private func beginText(at p: CGPoint, existing: Annotation? = nil) {
        guard let model, let doc else { return }
        var size = model.fontSize, color = model.color.nsColor, width: CGFloat = 220, text = ""
        if let existing, case .text(let s, _, let fs) = existing.kind {
            size = fs; color = existing.color.nsColor; text = s
            width = existing.boxWidth ?? max(220, (existing.bounds?.width ?? 0) + 40)
            doc.hiddenAnnotationID = existing.id
            editingText = existing
            refresh()
        }
        let origin = viewPoint(p)
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: width * zoom, height: size * zoom * 1.5))
        field.font = .systemFont(ofSize: size * zoom, weight: .medium)
        field.textColor = color
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.focusRingType = .none
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = p
    }

    func commitText() {
        guard let field = textField, let model, let doc else { return }
        textField = nil
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        if let original = editingText {
            editingText = nil
            doc.hiddenAnnotationID = nil
            if s.isEmpty {
                doc.removeAnnotation(original.id)
            } else if case .text(let old, let o, let size) = original.kind, old != s {
                var edited = original
                edited.kind = .text(s, origin: o, fontSize: size)
                doc.replaceAnnotation(edited, record: true)
            }
            selectedID = s.isEmpty ? nil : original.id
            refresh()
        } else if !s.isEmpty {
            let a = Annotation(.text(s, origin: textOrigin, fontSize: model.fontSize), color: model.color.rgba)
            addAndSelect(a)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
        window?.makeFirstResponder(self)
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard textField == nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c": copySelection(); return true
        case "v": pasteImage(); return true
        case "s": model?.saveAs(); return true
        case "a": selection = doc?.bounds; model?.tool = .select; needsDisplay = true; return true
        case "z": event.modifierFlags.contains(.shift) ? redo() : undo(); return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let doc else { return }
        switch event.keyCode {
        case 36, 76: // return
            if doc.patch != nil { doc.commitPatch(); refresh() }
            else if let c = cropRect { doc.crop(to: c); reload() }
        case 51, 117: // delete / forward delete
            if let a = selectedAnnotation { doc.removeAnnotation(a.id); selectedID = nil; refresh() }
            else if doc.patch != nil { doc.deletePatch(); refresh() }
            else if let s = selection { doc.erase(s); selection = nil; refresh() }
            else if cropRect != nil, model?.tool == .crop { cropRect = nil; needsDisplay = true }
        case 53: // esc
            if selectedID != nil { selectedID = nil }
            else if doc.patch != nil { doc.cancelPatch() }
            cropRect = nil; selection = nil; needsDisplay = true
        case 123, 124, 125, 126:
            guard let patch = doc.patch else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let d: CGSize = event.keyCode == 123 ? CGSize(width: -step, height: 0) : event.keyCode == 124 ? CGSize(width: step, height: 0)
                : event.keyCode == 125 ? CGSize(width: 0, height: step) : CGSize(width: 0, height: -step)
            doc.setPatchRect(patch.rect.offsetBy(dx: d.width, dy: d.height)); needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    // MARK: Edit commands

    var selectionRect: CGRect? { selection }

    func copySelection() {
        guard let doc else { return }
        if let patch = doc.patch { Clipboard.write(patch.image); model?.status = "已复制浮动块"; return }
        if let s = selection, let img = doc.copyRegion(s) { Clipboard.write(img); model?.status = "已复制选区 \(img.width)×\(img.height)"; return }
        Clipboard.write(doc.flattened()); model?.status = "已复制整张图片"
    }

    func pasteImage() {
        guard let doc, let img = Clipboard.readImage() else { model?.status = "剪贴板里没有图片"; return }
        let inside = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        let anchor = inside ? mouseInImage : CGPoint(x: doc.size.width / 2, y: doc.size.height / 2)
        selection = nil
        model?.tool = .select
        doc.paste(img, centeredAt: anchor)
        model?.status = "已粘贴：拖动移动，拖手柄拉伸，点「确认」或回车固定，Esc 取消"
        needsDisplay = true
    }

    func undo() { doc?.undo(); reload() }
    func redo() { doc?.redo(); reload() }

    func finishPatch() { doc?.commitPatch(); refresh() }

    // MARK: Styling the selected annotation

    enum StyleChange { case color, width, font }

    /// Tool settings changed: apply to the selected annotation too.
    func styleChanged(_ change: StyleChange) {
        guard !suppressStyle, let m = model, let doc, var a = selectedAnnotation else { return }
        switch change {
        case .color: a.color = m.color.rgba
        case .width:
            switch a.kind {
            case .text, .number: return
            default: a.lineWidth = m.lineWidth
            }
        case .font:
            guard case .text(let s, let o, _) = a.kind else { return }
            a.kind = .text(s, origin: o, fontSize: m.fontSize)
        }
        doc.replaceAnnotation(a, record: styleRecordedID != a.id)
        styleRecordedID = a.id
        refresh()
    }

    private func loadStyle(from a: Annotation) {
        guard let m = model else { return }
        suppressStyle = true
        m.colorValue = Color(.sRGB, red: a.color.r, green: a.color.g, blue: a.color.b, opacity: a.color.a)
        switch a.kind {
        case .text(_, _, let fs): m.fontSize = fs
        case .number: break
        default: m.lineWidth = a.lineWidth
        }
        suppressStyle = false
        styleRecordedID = nil
    }
    func cancelPatch() { doc?.cancelPatch(); needsDisplay = true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: model?.tool == .select ? .arrow : .crosshair) }
}
