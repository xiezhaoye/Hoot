import AppKit
import SwiftUI
import ShotPadCore

/// Draws the document and turns mouse/keyboard input into edits.
/// Image pixels map to view points through `zoom` (points per pixel).
final class CanvasView: NSView, NSTextFieldDelegate {
    weak var model: EditorModel?
    private(set) var zoom: CGFloat = 0.5
    private var cache: CGImage?
    private var panOrigin: (mouse: CGPoint, scroll: CGPoint)?

    // interaction state
    private var dragStart: CGPoint?
    private var draftPoints: [CGPoint] = []
    private var draftRect: CGRect?
    private var selection: CGRect?
    private var cropRect: CGRect?
    private enum PatchDrag { case move(grab: CGPoint, origin: CGRect), resize(Handle, CGRect) }
    private var patchDrag: PatchDrag?
    private var textField: NSTextField?
    private var editRect: CGRect = .zero         // text box while typing, image pixels
    private var editFont: CGFloat = 28
    private var editWidthSet = false
    private enum EditDrag { case move(grab: CGPoint, origin: CGRect), resize(Handle, CGRect, font: CGFloat) }
    private var editDrag: EditDrag?
    private let textPad: CGFloat = 4
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
    // while typing, clicks on the box handles must not steal focus from the field (that would end editing)
    override var acceptsFirstResponder: Bool { textField == nil }

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

    // MARK: Zoom

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Changes the zoom keeping the image point under `anchor` (view coordinates) where it is on screen.
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        guard doc != nil, let clip = enclosingScrollView?.contentView else { return }
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
    }

    /// Re-renders after the document (or its identity) changed.
    func reload(resetScroll: Bool = false) {
        guard doc != nil else { return }
        commitText()
        selection = nil; cropRect = nil; draftRect = nil; draftPoints = []; selectedID = nil; annDrag = nil
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        zoom = 1 / scale
        model?.zoomPercent = 100
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
            drawHandles(viewRect(editRect))
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
        let p = imagePoint(event)
        if textField != nil {
            if let h = Handle.allCases.first(where: { abs($0.point(in: editRect).x - p.x) <= 8 / zoom && abs($0.point(in: editRect).y - p.y) <= 8 / zoom }) {
                editDrag = .resize(h, editRect, font: editFont); dragStart = p; return
            }
            if editRect.insetBy(dx: -14 / zoom, dy: -14 / zoom).contains(p) {
                editDrag = .move(grab: p, origin: editRect); dragStart = p; return
            }
            commitText()
        }
        window?.makeFirstResponder(self)
        if model.tool == .hand, !(doc.patch.map { $0.rect.contains(p) || $0.hitHandle(at: p, slop: 7 / zoom) != nil } ?? false),
           let clip = enclosingScrollView?.contentView {
            panOrigin = (event.locationInWindow, clip.bounds.origin)
            NSCursor.closedHand.set()
            return
        }
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
            addAndSelect(Annotation(.number(doc.nextNumber(), center: p, diameter: max(24, model.lineWidth * 7)), color: model.color.rgba))
            dragStart = nil
        default: break
        }
        needsDisplay = true
    }

    private func matchesDrawingTool(_ t: Tool) -> Bool {
        t == .rect || t == .ellipse || t == .line || t == .arrow || t == .text || t == .number
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
            case .resize(let h, let original, let font):
                let r = Patch.resized(original, handle: h, to: p)
                if h == .left || h == .right {
                    editWidthSet = true
                    editRect = CGRect(x: r.minX, y: original.minY, width: max(40, r.width), height: original.height)
                } else {
                    let vertical = h == .top || h == .bottom
                    let ratio = max(0.1, vertical ? r.height / original.height : r.width / original.width)
                    let w = original.width * ratio, hgt = original.height * ratio
                    editRect = CGRect(x: h.movesLeft ? original.maxX - w : original.minX,
                                      y: h.movesTop ? original.maxY - hgt : original.minY, width: w, height: hgt)
                    editFont = max(8, font * ratio)
                }
            }
            syncEditField()
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
        if panOrigin != nil { panOrigin = nil; window?.invalidateCursorRects(for: self); return }
        guard let model, let doc, let s = dragStart else { dragStart = nil; return }
        if editDrag != nil { editDrag = nil; dragStart = nil; if let f = textField { window?.makeFirstResponder(f) }; return }
        defer { dragStart = nil; patchDrag = nil; annDrag = nil; editDrag = nil; draftRect = nil; draftPoints = []; needsDisplay = true }
        if annDrag != nil || editDrag != nil { return }
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
        case .pen: AppSettings.shared.noteUsed(color); doc.add(Annotation(.pen(draftPoints + [e]), color: color, lineWidth: w)); refresh()
        case .highlighter: AppSettings.shared.noteUsed(color); doc.add(Annotation(.highlighter(draftPoints + [e]), color: color, lineWidth: w)); refresh()
        case .mosaic where big: doc.add(Annotation(.mosaic(r, block: max(6, Int(w) * 3)))); refresh()
        case .blur where big: doc.add(Annotation(.blur(r, radius: max(4, Double(w) * 3)))); refresh()
        default: break
        }
    }

    // MARK: Text tool

    private func addAndSelect(_ a: Annotation) {
        AppSettings.shared.noteUsed(a.color)
        doc?.add(a)
        selectedID = a.id
        refresh()
    }

    private func beginText(at p: CGPoint, existing: Annotation? = nil) {
        guard let model, let doc else { return }
        var size = model.fontSize, color = model.color.nsColor, text = ""
        let pad = textPad
        editWidthSet = false
        if let existing, case .text(let str, _, let fs) = existing.kind, let b = existing.bounds {
            size = fs; color = existing.color.nsColor; text = str
            editWidthSet = existing.boxWidth != nil
            // wider than the text so there is room to keep typing, a little taller than the glyphs
            editRect = CGRect(x: b.minX - pad, y: b.minY - pad, width: b.width + 2 * pad + (editWidthSet ? 0 : 60), height: b.height + 2 * pad)
            doc.hiddenAnnotationID = existing.id
            editingText = existing
            refresh()
        } else {
            let h = Renderer.textSize("Ag", fontSize: size).height
            editRect = CGRect(x: p.x - pad, y: p.y - pad, width: max(200, size * 8), height: h + 2 * pad)
        }
        editFont = size
        let field = NSTextField(frame: .zero)
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.textColor = color
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.placeholderString = "输入文字，回车确认，⇧回车换行"
        field.delegate = self
        addSubview(field)
        textField = field
        syncEditField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func syncEditField() {
        guard let field = textField else { return }
        field.frame = viewRect(editRect)
        field.font = .systemFont(ofSize: editFont * zoom, weight: .medium)
    }

    func commitText() {
        guard let field = textField, let model, let doc else { return }
        textField = nil
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        let avail = editRect.width - 2 * textPad
        let natural = Renderer.textSize(s, fontSize: editFont).width
        let wrapWidth: CGFloat? = (editWidthSet || natural > avail + 1) ? avail : nil
        let origin = CGPoint(x: editRect.minX + textPad, y: editRect.minY + textPad)
        if let original = editingText {
            editingText = nil
            doc.hiddenAnnotationID = nil
            if s.isEmpty {
                doc.removeAnnotation(original.id)
            } else {
                var edited = original
                edited.kind = .text(s, origin: origin, fontSize: editFont)
                edited.boxWidth = wrapWidth
                doc.replaceAnnotation(edited, record: true)
            }
            selectedID = s.isEmpty ? nil : original.id
            refresh()
        } else if !s.isEmpty {
            var a = Annotation(.text(s, origin: origin, fontSize: editFont), color: model.color.rgba)
            a.boxWidth = wrapWidth
            model.fontSize = editFont
            addAndSelect(a)
        }
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        // grow the box when the text no longer fits
        let need = Renderer.textSize(field.stringValue, fontSize: editFont, width: editRect.width - 2 * textPad).height + 2 * textPad
        if need > editRect.height { editRect.size.height = need; syncEditField(); needsDisplay = true }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        commitText()
        window?.makeFirstResponder(self)
        return true
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
        case "x": cutSelection(); return true
        case "c": copySelection(); return true
        case "v": pasteImage(); return true
        case "s": model?.saveAs(); return true
        case "a": selection = doc?.bounds; model?.tool = .select; needsDisplay = true; return true
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

    func cutSelection() {
        guard let doc else { return }
        if let patch = doc.patch {
            Clipboard.write(patch.image); doc.deletePatch(); refresh(); model?.status = "已剪切浮动块"
        } else if let s = selection, let img = doc.copyRegion(s) {
            Clipboard.write(img); doc.erase(s); selection = nil; refresh(); model?.status = "已剪切选区 \(img.width)×\(img.height)，可粘贴到本图或其他历史截图"
        } else { NSSound.beep() }
    }

    // responder-chain entry points, so the Edit menu and the context menu work too
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

    override func resetCursorRects() { addCursorRect(bounds, cursor: model?.tool == .hand ? .openHand : .crosshair) }
}
