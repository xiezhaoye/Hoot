import AppKit
import ShotPadCore

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

struct CaptureResult {
    let image: CGImage
    /// Captured area in Cocoa screen coordinates (bottom-left origin).
    let screenRect: CGRect
}

/// Full-screen frozen screenshot on one display; the user drags a region or clicks a hovered window.
final class OverlayView: NSView {
    let shot: ScreenShot
    let windows: [WindowInfo]
    /// A region was picked or adjusted; the overlay stays up so it can still be changed.
    var onSelect: (CaptureResult) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPresentationChange: (CGRect) -> Void = { _ in }
    private var resultPresentation: ImagePreviewTransform?
    var isShowingSharedResult: Bool { resultPresentation != nil }
    private var editingScale: CGFloat { resultPresentation?.pixelsPerPoint ?? shot.scale }
    var selectedScreenRect: CGRect? {
        selection.map { CGRect(x: shot.screen.frame.minX + $0.minX, y: shot.screen.frame.maxY - $0.maxY, width: $0.width, height: $0.height) }
    }
    private enum Adjust { case move(grab: CGPoint, origin: CGRect), resize(Handle, CGRect) }
    private var adjust: Adjust?
    private(set) var committed = false
    var hasSelection: Bool { committed && selection != nil }
    var sharedResultFrame: CGRect? { resultPresentation?.frame }
    private var cursor: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hover: CGRect?
    private var candidates: [CGRect] = []
    private var candidateIndex = 0
    private var visualRegions: [CGRect] = []
    private var detailedRegions: [CGRect] = []
    private let ownRegions: [CGRect]
    private let smartCapture: Bool
    private let cornerRadius: CGFloat
    private let resolver = CaptureRegionResolver()
    private var queryGeneration = 0
    private var lastQueryPoint: CGPoint?
    private var lastQueryWindow: CGWindowID?
    private var wheelTotal: CGFloat = 0
    private var userChoseCandidate = false
    private let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    fileprivate let tools: QuickToolState
    /// Everything drawn on the shot lives in one editor document spanning the whole display (display pixels, top-left origin),
    /// so annotations, floating blocks, undo and the select / copy / paste logic match the main editor and survive region changes.
    var doc: EditorDocument?
    fileprivate var preview: CGImage?                 // the whole document rendered (display pixels); nil while nothing was changed
    fileprivate var drawing: (start: CGPoint, points: [CGPoint])?
    fileprivate enum ObjectDrag {
        case annotation(original: Annotation, grab: CGPoint)
        case patchMove(origin: CGRect, grab: CGPoint)
        case patchResize(Handle, CGRect)
        case lift(CGRect, handle: Handle?, grab: CGPoint)      // marquee edge / interior: lifts the content, then stretches or moves it
        case marqueeResize(Handle, CGRect)                      // marquee corner: resizes the frame only
        case annotationHandle(AnnotationHandle, original: Annotation, grab: CGPoint)
    }
    fileprivate var objectDrag: (kind: ObjectDrag, recorded: Bool)?
    fileprivate var marquee: CGRect?                  // the editor's "选区" marquee, display pixels
    fileprivate var marqueeStart: CGPoint?
    fileprivate var selectedID: UUID?
    private var nextNumberAfterFix = 1
    fileprivate var textField: NSTextView?
    fileprivate var editingOriginal: Annotation?      // the text being re-edited; put back when the edit is cancelled
    private var editRect = CGRect.zero
    private var editFont: CGFloat = 19
    private var editWidth: CGFloat?
    private var editWrap: CGFloat?
    private var editPad: CGFloat { 4 * editingScale }
    private enum TextDrag { case move(CGPoint, CGRect), resize(Handle, CGRect, CGFloat, CGFloat?) }
    private var textDrag: TextDrag?
    var isEditingText: Bool { textField != nil }
    var pixelScale: CGFloat { 1 }       // the editor nudges whole document pixels
    var hasSelectedObject: Bool { selectedID != nil || doc?.patch != nil || marquee != nil }

    init(shot: ScreenShot, windows: [WindowInfo], ownRegions: [CGRect], tools: QuickToolState? = nil) {
        self.shot = shot
        self.tools = tools ?? CaptureOverlay.shared.tools
        self.windows = windows
        self.ownRegions = ownRegions
        smartCapture = AppSettings.shared.smartCapture
        cornerRadius = AppSettings.shared.roundedCapture ? CGFloat(max(0, AppSettings.shared.captureRadius.isFinite ? AppSettings.shared.captureRadius : 0)) : 0
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("截图，拖动框选，Tab 切换范围，回车截图，Esc 取消")
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    func startDetection() {
        // A click immediately after opening capture must work without a mouse-moved event.
        let mouse = NSEvent.mouseLocation
        cursor = CGPoint(x: mouse.x - shot.screen.frame.minX, y: shot.screen.frame.maxY - mouse.y)
        updateTarget()
        guard smartCapture else { return }
        let image = shot.image
        let globalBounds = global(.zero)
        let screenRect = CGRect(origin: globalBounds, size: bounds.size)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let regions = CaptureVisualRegions.detect(image: image, screenRect: screenRect)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.visualRegions = regions
                if self.dragStart == nil { self.updateTarget(preserveSelection: self.userChoseCandidate) }
            }
        }
    }

    private func updateTarget(preserveSelection: Bool = false, query: Bool = true) {
        guard let cursor, dragStart == nil, !committed else { return }
        guard bounds.contains(cursor) else { hover = nil; candidates = []; needsDisplay = true; return }
        let point = global(cursor)
        guard let target = windows.first(where: { $0.rect.contains(point) }) else {
            hover = nil; candidates = []; needsDisplay = true; return
        }
        let sameWindow = lastQueryWindow == target.windowID
        if !sameWindow { detailedRegions = [] }
        let localOwn = target.ownerPID == getpid() ? ownRegions : []
        let regions = smartCapture ? visualRegions + localOwn + (sameWindow ? detailedRegions : []) : []
        let previous = preserveSelection ? hover : nil
        candidates = CaptureGeometry.candidates(at: point, window: target.rect, regions: regions)
        candidateIndex = previous.flatMap { old in candidates.firstIndex { local($0).intersection(bounds) == old } } ?? 0
        hover = candidates.isEmpty ? nil : local(candidates[candidateIndex]).intersection(bounds)
        updateAccessibilityLabel()
        needsDisplay = true
        guard smartCapture, query else { return }
        if let last = lastQueryPoint, sameWindow, hypot(last.x - point.x, last.y - point.y) < 5 { return }
        queryGeneration += 1; let generation = queryGeneration
        lastQueryPoint = point; lastQueryWindow = target.windowID
        resolver.query(point: point, ownerPID: target.ownerPID) { [weak self] regions in
            guard let self, self.window != nil, self.dragStart == nil, generation == self.queryGeneration else { return }
            self.detailedRegions = regions
            self.updateTarget(preserveSelection: self.userChoseCandidate, query: false)
        }
    }

    private func cycleTarget(_ delta: Int) {
        guard dragStart == nil, !committed, !candidates.isEmpty else { return }
        userChoseCandidate = true
        candidateIndex = (candidateIndex + delta + candidates.count) % candidates.count
        hover = local(candidates[candidateIndex]).intersection(bounds); updateAccessibilityLabel(); needsDisplay = true
    }
    private func pixelRect(_ r: CGRect) -> CGRect {
        if let resultPresentation {
            let origin = resultPresentation.imagePoint(r.origin)
            return CGRect(x: origin.x, y: origin.y, width: r.width * editingScale, height: r.height * editingScale)
                .integral.intersection(CGRect(origin: .zero, size: resultPresentation.imageSize))
        }
        return CGRect(x: r.minX * editingScale, y: r.minY * editingScale, width: r.width * editingScale, height: r.height * editingScale)
            .integral.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
    }
    private func updateAccessibilityLabel() {
        guard let r = selection ?? hover, !r.isNull else { return }
        let px = pixelRect(r)
        let mode = selection != nil ? "手动选区" : "截图选区"
        setAccessibilityLabel("\(mode) \(Int(px.width)) × \(Int(px.height)) 像素，范围 \(candidateIndex + 1)/\(candidates.count)，Tab 切换，回车截图，Esc 取消")
    }
    override func scrollWheel(with event: NSEvent) {
        guard !tools.isProcessing else { return }
        if var presentation = resultPresentation {
            finishText(commit: true)
            if event.modifierFlags.contains(.command) {
                presentation.zoom(by: exp(event.scrollingDeltaY * 0.015), at: convert(event.locationInWindow, from: nil), within: previewViewport)
            } else {
                presentation.move(to: CGPoint(x: presentation.frame.minX + event.scrollingDeltaX, y: presentation.frame.minY + event.scrollingDeltaY), within: previewViewport)
            }
            updatePresentation(presentation); return
        }
        wheelTotal += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        if abs(wheelTotal) >= threshold { cycleTarget(wheelTotal > 0 ? 1 : -1); wheelTotal = 0 }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { textField == nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if textField != nil, case .resize = textBoxHit(displayPixel(local)) { return self }
        return super.hitTest(point)
    }

    func clearSelection() {
        guard committed || selection != nil else { return }
        committed = false; selection = nil; adjust = nil
        resetAnnotations(); tools.reset()
        updateTarget(preserveSelection: false, query: false)
        needsDisplay = true
    }

    /// Return with nothing picked yet takes the highlighted region.
    func commitHover() { if !committed { commit(hover) } }

    private var previewViewport: CGRect {
        let inset = bounds.insetBy(dx: 24, dy: 72)
        return inset.width > 40 && inset.height > 40 ? inset : bounds
    }

    /// Replace the picked region with a full-resolution result, keeping this overlay and its editing tools alive.
    func showSharedResult(_ image: CGImage) {
        let anchor = selection ?? previewViewport
        resetAnnotations()
        doc = EditorDocument(image: image)
        let presentation = ImagePreviewTransform(imageSize: CGSize(width: image.width, height: image.height),
            around: anchor, within: previewViewport, nativeScale: shot.scale)
        resultPresentation = presentation; selection = presentation.frame; hover = nil; committed = true
        bindTools(); tools.tool = .hand
        refreshPreview(); updateAccessibilityLabel()
        window?.makeFirstResponder(self)
        if let selectedScreenRect { onPresentationChange(selectedScreenRect) }
    }

    private func updatePresentation(_ presentation: ImagePreviewTransform) {
        resultPresentation = presentation; selection = presentation.frame
        if let id = selectedID, let a = doc?.annotation(id), case .text(_, _, let size) = a.kind {
            tools.setFontSizeSilently(size / editingScale)
        }
        updateAccessibilityLabel(); needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if let selectedScreenRect { onPresentationChange(selectedScreenRect) }
    }

    override func magnify(with event: NSEvent) {
        guard !tools.isProcessing, var presentation = resultPresentation else { return }
        finishText(commit: true)
        presentation.zoom(by: max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil), within: previewViewport)
        updatePresentation(presentation)
    }

    private func bindTools() {
        tools.undo = { [weak self] in self?.undo() }
        tools.reselect = { [weak self] in self?.clearSelection(); self?.onClear() }
        tools.cut = { [weak self] in
            guard let self else { return }
            let canCut = self.marquee != nil || self.doc?.patch != nil
            self.cutSelection(); self.tools.showEditStatus(canCut ? "已剪切" : "请先选择区域")
        }
        tools.copy = { [weak self] in
            guard let self else { return }
            self.tools.showEditStatus(self.copySelection() ? "已复制图片" : "无法复制图片")
        }
        tools.paste = { [weak self] in
            guard let self else { return }
            self.tools.showEditStatus(self.pasteImage() ? "已粘贴，可移动和缩放" : "剪贴板中没有图片")
        }
        tools.onStyle = { [weak self] in self?.styleChanged() }
        tools.onToolChange = { [weak self] in self?.toolChanged() }
    }

    private func resizeCursor(_ h: Handle) -> NSCursor {
        let pos: NSCursor.FrameResizePosition
        switch h {
        case .topLeft: pos = .topLeft; case .top: pos = .top; case .topRight: pos = .topRight; case .right: pos = .right
        case .bottomRight: pos = .bottomRight; case .bottom: pos = .bottom; case .bottomLeft: pos = .bottomLeft; case .left: pos = .left
        }
        return NSCursor.frameResize(position: pos, directions: .all)
    }

    private func adjustCursor(at p: CGPoint) {
        guard let s = selection else { return }
        let q = displayPixel(p)
        if textField != nil {
            switch textBoxHit(q) {
            case .resize(let h): resizeCursor(h).set(); return
            case .move: NSCursor.openHand.set(); return
            case nil: break
            }
        }
        if let id = selectedID, let a = doc?.annotation(id), matches(a, tools.tool), let hit = a.editingHit(at: q, slop: 7 * editingScale) {
            switch hit {
            case .handle(.box(let handle)): resizeCursor(handle).set()
            case .handle(.start), .handle(.end), .move: NSCursor.openHand.set()
            }
            return
        }
        if tools.tool == .select, let m = marquee, textField == nil {
            if let h = Handle.hit(in: m, at: q, slop: 7 * editingScale) { resizeCursor(h).set(); return }
            if m.contains(q) { NSCursor.openHand.set(); return }
        }
        if let h = doc?.selectedPatchID.flatMap({ id in doc?.patches.first { $0.id == id } }).flatMap({ b in Handle.hit(in: b.rect, at: q, slop: 6 * editingScale) }) {
            resizeCursor(h).set(); return
        }
        if doc?.patch?.rect.contains(q) == true { NSCursor.openHand.set(); return }
        if let h = Handle.hit(in: s, at: p, slop: 8) {
            resizeCursor(h).set()
        } else if s.contains(p) { (tools.tool == .hand ? NSCursor.openHand : NSCursor.crosshair).set() } else { NSCursor.crosshair.set() }
    }

    /// Screen-local point (top-left origin) -> global top-left coordinates.
    private func global(_ p: CGPoint) -> CGPoint {
        CaptureGeometry.global(p, screen: shot.screen.frame, primaryHeight: primaryHeight)
    }

    private func local(_ r: CGRect) -> CGRect {
        CaptureGeometry.local(r, screen: shot.screen.frame, primaryHeight: primaryHeight)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !tools.isProcessing else { NSCursor.arrow.set(); return }
        cursor = convert(event.locationInWindow, from: nil)
        if committed, let cursor { adjustCursor(at: cursor); return }
        userChoseCandidate = false
        updateTarget()
    }

    override func mouseDown(with event: NSEvent) {
        guard !tools.isProcessing else { return }
        cursor = convert(event.locationInWindow, from: nil)
        if let p = cursor, textField != nil {
            let q = displayPixel(p)
            switch textBoxHit(q) {
            case .resize(let h): textDrag = .resize(h, editRect, editFont, editWidth); return
            case .move: textDrag = .move(q, editRect); return
            case nil: break
            }
        }
        finishText(commit: true)
        if committed, let s = selection, let p = cursor {
            let onHandle = Handle.hit(in: s, at: p, slop: 8)
            let shift = event.modifierFlags.contains(.shift), clicks = event.clickCount
            // the marquee, a floating block and a selected object own their handles even beside the region's own edge
            if onHandle == nil, s.contains(p) || objectOwns(p) { objectMouseDown(at: p, shift: shift, clicks: clicks); return }
            if let h = onHandle {
                if objectOwns(p) { objectMouseDown(at: p, shift: shift, clicks: clicks); return }
                adjust = .resize(h, s); dragStart = p; return
            }
            committed = false; resetAnnotations(); tools.reset(); onClear()      // clicking outside starts a fresh selection
        }
        updateTarget(preserveSelection: true, query: false)
        dragStart = cursor
        queryGeneration += 1; resolver.cancel()
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !tools.isProcessing else { return }
        if let drag = textDrag {
            let q = displayPixel(convert(event.locationInWindow, from: nil))
            switch drag {
            case .move(let grab, let rect): editRect = rect.offsetBy(dx: q.x - grab.x, dy: q.y - grab.y)
            case .resize(let h, let rect, let font, let width):
                if h == .left || h == .right {
                    editWidth = max(40 * editingScale, (h == .left ? rect.maxX - q.x : q.x - rect.minX) - editPad * 2)
                    layoutTextBox()
                    if h == .left { editRect.origin.x = rect.maxX - editRect.width }
                } else {
                    let anchor = CGPoint(x: h.movesLeft ? rect.maxX : rect.minX, y: h.movesTop ? rect.maxY : rect.minY)
                    let dx = (q.x - anchor.x) * (h.movesLeft ? -1 : 1), dy = (q.y - anchor.y) * (h.movesTop ? -1 : 1)
                    let ratio = max(0.1, (dx * rect.width + dy * rect.height) / max(1, rect.width * rect.width + rect.height * rect.height))
                    editFont = max(8, min(1000, font * ratio)); editWidth = width.map { $0 * editFont / font }
                    tools.setFontSizeSilently(editFont / editingScale)
                    layoutTextBox()
                    editRect.origin = CGPoint(x: h.movesLeft ? anchor.x - editRect.width : anchor.x, y: h.movesTop ? anchor.y - editRect.height : anchor.y)
                }
            }
            syncTextField(); needsDisplay = true; return
        }
        if drawing != nil || objectDrag != nil || marqueeStart != nil {
            cursor = convert(event.locationInWindow, from: nil)
            if let p = cursor { objectMouseDragged(to: p, shift: event.modifierFlags.contains(.shift)) }
            return
        }
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if var presentation = resultPresentation, let adjust {
            switch adjust {
            case .move(let grab, let origin):
                presentation.move(to: CGPoint(x: origin.minX + p.x - grab.x, y: origin.minY + p.y - grab.y), within: previewViewport)
            case .resize(let h, let origin):
                presentation.resize(h, to: p, from: origin, within: previewViewport)
            }
            updatePresentation(presentation); return
        }
        cursor = p
        if let a = adjust {
            switch a {
            case .move(let grab, let origin):
                var r = origin.offsetBy(dx: p.x - grab.x, dy: p.y - grab.y)
                r.origin.x = min(max(0, r.minX), max(0, bounds.width - r.width))
                r.origin.y = min(max(0, r.minY), max(0, bounds.height - r.height))
                selection = r
            case .resize(let h, let original):
                selection = Patch.resized(original, handle: h, to: p).intersection(bounds)
            }
            updateAccessibilityLabel(); needsDisplay = true
            return
        }
        selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)).intersection(bounds)
        hover = nil
        updateAccessibilityLabel(); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !tools.isProcessing else { return }
        if textDrag != nil { textDrag = nil; if let field = textField { window?.makeFirstResponder(field) }; return }
        if drawing != nil || objectDrag != nil || marqueeStart != nil { objectMouseUp(shift: event.modifierFlags.contains(.shift)); return }
        defer { dragStart = nil; adjust = nil }
        if adjust != nil { commit(selection); return }
        let rect: CGRect?
        if let s = selection, s.width >= 4, s.height >= 4 { rect = s } else { rect = hover }
        commit(rect)
    }

    private func commit(_ rect: CGRect?) {
        guard let r = rect, r.width >= 2, r.height >= 2 else { selection = nil; committed = false; needsDisplay = true; return }
        selection = r; hover = nil; committed = true
        updateAccessibilityLabel(); needsDisplay = true
        if isShowingSharedResult {
            if let selectedScreenRect { onPresentationChange(selectedScreenRect) }
            return
        }
        let px = pixelRect(r)
        guard let cropped = shot.image.cropping(to: px) else { return }
        let f = shot.screen.frame
        let rounded = CaptureGeometry.rounded(cropped, radius: cornerRadius)
        bindTools()
        refreshPreview()
        onSelect(CaptureResult(image: rounded, screenRect: CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)))
    }

    override func keyDown(with event: NSEvent) {
        guard !tools.isProcessing else { return }
        if var presentation = resultPresentation, event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(), ["=", "+", "-", "0"].contains(key) {
            finishText(commit: true)
            if key == "0" {
                presentation = ImagePreviewTransform(imageSize: presentation.imageSize, around: previewViewport, within: previewViewport, nativeScale: shot.scale)
            } else {
                presentation.zoom(by: key == "-" ? 0.8 : 1.25, at: CGPoint(x: previewViewport.midX, y: previewViewport.midY), within: previewViewport)
            }
            updatePresentation(presentation); return
        }
        if event.keyCode == 48 { cycleTarget(event.modifierFlags.contains(.shift) ? -1 : 1) }
        else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) { guard !tools.isProcessing else { return }; if committed { clearSelection(); onClear() } else { onCancel() } }

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: shot.image, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill(using: .sourceOver)
        defer { if !committed { drawGuides(); drawMagnifier() } }
        guard let r = selection ?? hover else { return }
        NSGraphicsContext.saveGraphicsState()
        let radius = isShowingSharedResult ? 0 : min(cornerRadius / editingScale, min(r.width, r.height) / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        path.addClip()
        if isShowingSharedResult, let preview {
            NSColor.white.setFill(); r.fill()
            NSImage(cgImage: preview, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            if let preview { NSImage(cgImage: preview, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil) }
        }
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            if isShowingSharedResult { ctx.translateBy(x: r.minX, y: r.minY) }
            ctx.scaleBy(x: 1 / editingScale, y: 1 / editingScale)
            drawEditingOverlays(in: ctx)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        AppSettings.shared.selectionNSColor.setStroke()
        path.stroke()
        if committed {
            for h in Handle.allCases {
                let q = h.point(in: r)
                let box = CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8)
                NSColor.white.setFill(); box.fill()
                AppSettings.shared.selectionNSColor.setStroke(); NSBezierPath(rect: box).stroke()
            }
        }
        let tip = isShowingSharedResult ? " · ⌘滚轮 / 捏合缩放，滚动查看" : selection == nil && candidates.count > 1 ? " · 滚轮 / Tab 切换范围" : ""
        let label = " \(Int(pixelRect(r).width)) × \(Int(pixelRect(r).height))\(tip) " as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.white,
                                                    .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
        let size = label.size(withAttributes: attrs)
        let labelX = isShowingSharedResult ? min(max(8, r.minX), max(8, bounds.maxX - size.width - 8)) : r.minX
        let labelY = r.minY >= size.height + 4 ? r.minY - size.height - 4 : r.minY + 4
        label.draw(at: CGPoint(x: labelX, y: isShowingSharedResult ? min(max(8, labelY), bounds.maxY - size.height - 8) : labelY), withAttributes: attrs)
    }
}

extension OverlayView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { layoutTextBox(); syncTextField(); needsDisplay = true }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finishText(commit: true); return true }
        return false
    }
}

extension OverlayView {
    // MARK: Editing the picked region (same model as the main editor)

    fileprivate func ensureDoc() -> EditorDocument {
        if let d = doc { return d }
        let d = EditorDocument(image: shot.image); doc = d; return d
    }

    /// The picked region with everything drawn on it; nil when nothing was changed.
    var annotatedImage: CGImage? {
        if isShowingSharedResult { return preview ?? doc?.state.base }
        guard doc?.isModified == true, let s = selection, let region = preview?.cropping(to: pixelRect(s)) else { return nil }
        return CaptureGeometry.rounded(region, radius: cornerRadius)
    }

    fileprivate func resetAnnotations() {
        finishText(commit: false)
        doc = nil; preview = nil; drawing = nil; objectDrag = nil; marquee = nil; marqueeStart = nil; selectedID = nil
        resultPresentation = nil
        nextNumberAfterFix = 1
        tools.canUndo = false; needsDisplay = true
    }

    fileprivate func refreshPreview() {
        preview = doc.flatMap { $0.isModified ? $0.composite() : isShowingSharedResult ? $0.state.base : nil }
        tools.canUndo = doc?.canUndo ?? false
        needsDisplay = true
    }

    fileprivate func undo() {
        finishText(commit: true)
        guard let d = doc, d.canUndo else { return }
        d.undo(); selectedID = nil; marquee = nil; refreshPreview()
    }

    fileprivate func redo() {
        guard let d = doc, d.canRedo else { return }
        d.redo(); selectedID = nil; refreshPreview()
    }

    fileprivate func deleteSelected() {
        guard marquee != nil || selectedID != nil || doc?.patch != nil else { return }
        let d = ensureDoc()
        if let id = selectedID { d.removeAnnotation(id); selectedID = nil }
        else if d.patch != nil { d.deletePatch() }
        else if let m = marquee { d.erase(m); marquee = nil }
        refreshPreview()
    }

    /// ⌘C: the floating block, else the marquee, goes to the clipboard.
    func copySelection() -> Bool {
        guard let s = selection else { return false }
        let d = ensureDoc()
        let image: CGImage?
        if let m = marquee { image = d.copyRegion(m) }
        else if let p = d.patch { image = p.rasterized() }
        else { image = annotatedImage ?? shot.image.cropping(to: pixelRect(s)) }      // nothing picked: the whole region, like the editor
        guard let image else { return false }
        Clipboard.write(image)
        return true
    }

    /// ⌘X: copy, then take the marquee / floating block off the picture.
    fileprivate func cutSelection() {
        guard marquee != nil || doc?.patch != nil, copySelection() else { return }
        let d = ensureDoc()
        if let m = marquee { d.erase(m); marquee = nil } else { d.deletePatch() }
        refreshPreview()
    }

    /// ⌘A: the whole region becomes the marquee.
    fileprivate func selectAllInRegion() {
        guard selection != nil else { return }
        finishText(commit: true)
        tools.tool = .select
        fixPatches(); selectedID = nil
        marquee = regionPixels; needsDisplay = true
    }

    /// Esc, step by step like the editor: deselect the drawing, drop the marquee, leave the tool. False = nothing left to undo,
    /// so the caller may take back the region itself.
    fileprivate func softEscape() -> Bool {
        if selectedID != nil { selectedID = nil; needsDisplay = true; return true }
        if doc?.patch != nil { fixPatches(); doc?.selectedPatchID = nil; needsDisplay = true; return true }
        if marquee != nil { marquee = nil; needsDisplay = true; return true }
        if tools.tool != .hand { tools.tool = .hand; return true }
        return false
    }

    fileprivate func nudgePatch(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let d = doc, let p = d.patch else { return false }
        d.setPatchRect(clamped(p.rect.offsetBy(dx: dx, dy: dy), in: regionPixels)); refreshPreview(); return true
    }

    /// ⌘V: the clipboard image becomes a floating block in the middle of the marquee (or the region).
    func pasteImage() -> Bool {
        guard let image = Clipboard.readImage(), let s = selection else { return false }
        let d = ensureDoc()
        finishText(commit: true)
        tools.tool = .select           // like the editor; this also fixes the previous block
        _ = fixPatches()
        let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let centre = displayPixel(s.contains(mouse) ? mouse : CGPoint(x: s.midX, y: s.midY))
        d.paste(image, centeredAt: centre)
        if let p = d.patch {
            let bounds = regionPixels
            let fit = min(1, bounds.width / p.rect.width, bounds.height / p.rect.height)
            let size = CGSize(width: max(1, p.rect.width * fit), height: max(1, p.rect.height * fit))
            let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
            d.setPatchRect(clamped(rect, in: bounds), record: false)
        }
        marquee = nil; selectedID = nil
        refreshPreview()
        return true
    }

    private func clamped(_ r: CGRect, in b: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(b.minX, r.minX), max(b.minX, b.maxX - r.width))
        r.origin.y = min(max(b.minY, r.minY), max(b.minY, b.maxY - r.height))
        return r
    }

    /// Floating blocks are fixed once the user moves on, like in the main editor. Returns whether anything was fixed.
    @discardableResult
    fileprivate func fixPatches() -> Bool {
        guard let d = doc, !d.patches.isEmpty else { return false }
        d.flattenPatches(); refreshPreview(); return true
    }

    fileprivate func toolChanged() {
        finishText(commit: true)
        fixObjects()
        selectedID = nil
        if tools.tool != .select { marquee = nil }
        needsDisplay = true
    }

    private func fixObjects() {
        guard let d = doc, d.hasEditableObjects else { return }
        nextNumberAfterFix = max(nextNumberAfterFix, d.nextNumber())
        d.flattenAll(); refreshPreview()
    }

    fileprivate func styleChanged() {
        if let f = textField {
            f.textColor = tools.color.nsColor
            editFont = tools.fontSize * editingScale
            layoutTextBox(); syncTextField(); needsDisplay = true
            return
        }
        guard let d = doc, let id = selectedID, let a = d.annotation(id) else { return }
        var changed = styled(a)
        if case .text(let text, let origin, _) = changed.kind {
            changed.kind = .text(text, origin: origin, fontSize: tools.fontSize * editingScale)
            changed.fontName = tools.fontName.isEmpty ? nil : tools.fontName
        }
        d.replaceAnnotation(changed, record: true)
        refreshPreview()
    }

    // MARK: Pointer

    /// View point -> display pixels (what the document is stored in).
    private func displayPixel(_ p: CGPoint) -> CGPoint {
        resultPresentation?.imagePoint(p) ?? CGPoint(x: p.x * editingScale, y: p.y * editingScale)
    }
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        resultPresentation?.viewPoint(p) ?? CGPoint(x: p.x / editingScale, y: p.y / editingScale)
    }

    private func clampedPixel(_ p: CGPoint) -> CGPoint {
        guard let s = selection else { return displayPixel(p) }
        return displayPixel(CGPoint(x: min(max(p.x, s.minX), s.maxX), y: min(max(p.y, s.minY), s.maxY)))
    }

    private var regionPixels: CGRect {
        if isShowingSharedResult, let doc { return doc.bounds }
        guard let s = selection else { return .zero }
        return CGRect(x: s.minX * editingScale, y: s.minY * editingScale, width: s.width * editingScale, height: s.height * editingScale)
    }

    /// The floating block under `q`: its body, or (for the selected block only) one of its eight handles.
    /// Handles are tight on purpose: a marquee started right beside a pasted block must not grab it.
    private func hitBlock(at q: CGPoint) -> (block: Patch, handle: Handle?)? {
        guard let d = doc else { return nil }
        let reach = 6 * editingScale
        for block in d.patches.reversed() where !block.isMask {
            if block.id == d.selectedPatchID,
               let h = Handle.allCases.first(where: { let c = $0.point(in: block.rect); return abs(c.x - q.x) <= reach && abs(c.y - q.y) <= reach }) { return (block, h) }
            if block.rect.contains(q) { return (block, nil) }
        }
        return nil
    }

    /// Whether `a` can be picked up with the current tool (same rule as the main editor).
    private func matches(_ a: Annotation, _ tool: Tool) -> Bool {
        switch (a.kind, tool) {
        case (.pen, .pen), (.highlighter, .highlighter), (_, .hand), (_, .select): return true
        case (.rect, .rect), (.ellipse, .ellipse), (.line, .line), (.arrow, .arrow), (.text, .text), (.number, .number): return true
        default: return false
        }
    }

    /// True when `p` is on something the object layer owns: a marquee edge / corner / interior, the handle of the selected
    /// floating block, or a handle of the selected drawing. These win over the region's own resize handles.
    fileprivate func objectOwns(_ p: CGPoint) -> Bool {
        let q = displayPixel(p), k = editingScale
        if tools.tool == .select, let m = marquee, Handle.hit(in: m, at: q, slop: 7 * k) != nil || m.contains(q) { return true }
        if hitBlock(at: q)?.handle != nil { return true }
        if let d = doc, let id = selectedID, let a = d.annotation(id), matches(a, tools.tool), a.editingHit(at: q, slop: 7 * k) != nil { return true }
        return false
    }

    fileprivate func objectMouseDown(at p: CGPoint, shift: Bool = false, clicks: Int = 1) {
        let k = editingScale, q = displayPixel(p)
        let tool = tools.tool
        // Select tool: the marquee owns its border and interior. Corners resize the frame; edges stretch and the interior
        // moves the content itself (lifted into a floating block on the first drag).
        if tool == .select, let m = marquee {
            let handle = Handle.hit(in: m, at: q, slop: 7 * k)
            if handle != nil || m.contains(q) {
                if let handle, [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle) { objectDrag = (.marqueeResize(handle, m), false) }
                else { objectDrag = (.lift(m, handle: handle, grab: q), false) }
                selectedID = nil; needsDisplay = true; return
            }
        }
        let hit = hitBlock(at: q)
        // a click away from the floating blocks fixes them
        if let d = doc, !d.patches.isEmpty, hit == nil { fixPatches() }
        if let d = doc, let h = hit, d.patchIsAboveAnnotations(h.block, at: q, slop: 6 * k),
           tool == .select || tool == .hand || h.block.id == d.selectedPatchID {
            d.selectedPatchID = h.block.id; selectedID = nil; marquee = nil
            if let handle = h.handle { objectDrag = (.patchResize(handle, h.block.rect), false) }
            else { objectDrag = (.patchMove(origin: h.block.rect, grab: q), false) }
            needsDisplay = true; return
        }
        doc?.selectedPatchID = nil
        let pickable = tool == .hand || tool == .select || [.pen, .highlighter, .rect, .ellipse, .line, .arrow, .text, .number].contains(tool)
        if pickable, let d = doc {
            if let id = selectedID, let sel = d.annotation(id), matches(sel, tool), let hit = sel.editingHit(at: q, slop: 7 * k) {
                if clicks >= 2, case .text = sel.kind, hit == .move { beginText(at: p, existing: sel); return }
                switch hit {
                case .handle(let h): objectDrag = (.annotationHandle(h, original: sel, grab: q), false)
                case .move: objectDrag = (.annotation(original: sel, grab: q), false)
                }
                marquee = nil; needsDisplay = true; return
            }
            if selectedID != nil { fixObjects(); selectedID = nil }
            if let hit = d.annotation(at: q, slop: 6 * k, matching: { matches($0, tool) }) {
                if clicks >= 2, case .text = hit.kind { beginText(at: p, existing: hit); return }
                selectedID = hit.id; marquee = nil
                let size: CGFloat
                if case .text(_, _, let font) = hit.kind { size = font / k } else { size = tools.fontSize }
                let width = hit.lineWidth / k * (tool == .highlighter ? 3 / 8 : 1)
                tools.loadStyle(color: hit.color, width: width, fontName: hit.fontName ?? "", fontSize: size)
                objectDrag = (.annotation(original: hit, grab: q), false)
                needsDisplay = true; return
            }
            selectedID = nil
        }
        switch tool {
        case .hand:
            adjust = .move(grab: p, origin: selection ?? .zero); dragStart = p      // empty spot: move the whole region
        case .select:
            marqueeStart = clampedPixel(p); marquee = nil; needsDisplay = true
        default:
            beginDraw(at: p)
        }
    }

    /// Shift: square / circle for boxes, horizontal / vertical / 45° for lines and arrows.
    private func shiftConstrained(_ end: CGPoint, from start: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return end }
        switch tools.tool {
        case .rect, .ellipse: return DrawingGeometry.squareEndpoint(from: start, to: end, within: regionPixels)
        case .line, .arrow: return DrawingGeometry.snappedEndpoint(from: start, to: end, within: regionPixels)
        default: return end
        }
    }

    fileprivate func objectMouseDragged(to p: CGPoint, shift: Bool = false) {
        let q = displayPixel(p), k = editingScale
        if let d = drawing {
            let end = shiftConstrained(clampedPixel(p), from: d.start, shift: shift)
            if tools.tool == .pen || tools.tool == .highlighter { drawing?.points.append(end) }
            else { drawing?.points = [d.start, end] }
            needsDisplay = true; return
        }
        if let start = marqueeStart {
            marquee = CGRect.spanning(start, clampedPixel(p)).intersection(regionPixels)
            needsDisplay = true; return
        }
        guard var drag = objectDrag else { return }
        let d = ensureDoc()      // the document is created lazily; a fresh marquee has none yet
        defer { objectDrag = drag; refreshPreview() }           // re-render each step so moves show exactly what will be copied
        switch drag.kind {
        case .annotation(let original, let grab):
            if !drag.recorded, hypot(q.x - grab.x, q.y - grab.y) < 3 * k { return }       // a click is not a drag
            var a = original; a.move(by: CGSize(width: (q.x - grab.x).rounded(), height: (q.y - grab.y).rounded()))
            d.replaceAnnotation(a, record: !drag.recorded); drag.recorded = true
        case .annotationHandle(let h, let original, let grab):
            if !drag.recorded, hypot(q.x - grab.x, q.y - grab.y) < 3 * k { return }
            let updated = original.dragged(h, to: clampedPixel(p))
            if case .text(_, _, let font) = updated.kind { tools.setFontSizeSilently(font / editingScale) }
            d.replaceAnnotation(updated, record: !drag.recorded); drag.recorded = true
        case .patchMove(let origin, let grab):
            let moved = origin.offsetBy(dx: (q.x - grab.x).rounded(), dy: (q.y - grab.y).rounded())
            d.setPatchRect(clamped(moved, in: regionPixels), record: !drag.recorded); drag.recorded = true
        case .patchResize(let h, let original):
            let r = Patch.resized(original, handle: h, to: CGPoint(x: q.x.rounded(), y: q.y.rounded())).intersection(regionPixels)
            d.setPatchRect(r, record: !drag.recorded); drag.recorded = true
        case .marqueeResize(let h, let original):
            marquee = Patch.resized(original, handle: h, to: clampedPixel(p)).intersection(regionPixels).integral
            drag.recorded = true
        case .lift(let m, let handle, let grab):
            guard hypot(q.x - grab.x, q.y - grab.y) > 2 * k, d.liftSelection(m), let patch = d.patch else { return }
            marquee = nil
            // lifting already recorded the undo step
            if let handle {
                let r = Patch.resized(patch.rect, handle: handle, to: CGPoint(x: q.x.rounded(), y: q.y.rounded())).intersection(regionPixels)
                d.setPatchRect(r, record: false)
                drag = (.patchResize(handle, patch.rect), true)
            } else {
                let moved = patch.rect.offsetBy(dx: (q.x - grab.x).rounded(), dy: (q.y - grab.y).rounded())
                d.setPatchRect(clamped(moved, in: regionPixels), record: false)
                drag = (.patchMove(origin: patch.rect, grab: grab), true)
            }
        }
    }

    fileprivate func objectMouseUp(shift: Bool = false) {
        if drawing != nil { finishDraw() }
        if marqueeStart != nil || marquee != nil, let m = marquee, m.width < 3 * editingScale || m.height < 3 * editingScale { marquee = nil }
        marqueeStart = nil
        objectDrag = nil; refreshPreview()
        needsDisplay = true
    }

    // MARK: Drawing tools

    // Strokes, text size, numbers and mosaic strength all follow the one width setting (points).
    private func styled(_ a: Annotation) -> Annotation {
        var a = a
        let k = editingScale, w = tools.width
        a.color = tools.color
        switch a.kind {
        case .highlighter: a.lineWidth = w * k * 8 / 3
        case .text(let t, let o, _): a.kind = .text(t, origin: o, fontSize: tools.fontSize * k); a.fontName = tools.fontName.isEmpty ? nil : tools.fontName
        case .number(let n, let c, _): a.kind = .number(n, center: c, diameter: (16 + w * 4) * k)
        case .mosaic(let r, _): a.kind = .mosaic(r, block: Int(max(4, w * 2.7 * k)))
        case .blur(let r, _): a.kind = .blur(r, radius: Double(w * 3.3 * k))
        default: a.lineWidth = w * k
        }
        return a
    }

    fileprivate func beginDraw(at p: CGPoint) {
        selectedID = nil
        let pt = clampedPixel(p)
        switch tools.tool {
        case .number:
            let d = ensureDoc()
            let a = styled(Annotation(.number(max(nextNumberAfterFix, d.nextNumber()), center: pt, diameter: 0)))
            d.add(a); selectedID = a.id
            refreshPreview()
        case .text:
            beginText(at: p)
        default:
            drawing = (pt, [pt]); needsDisplay = true
        }
    }

    fileprivate func finishDraw() {
        defer { drawing = nil; needsDisplay = true }
        guard let a = draftAnnotation(final: true) else { return }
        ensureDoc().add(a); selectedID = a.id
        refreshPreview()
    }

    /// The shape being dragged out (`final` builds the mosaic / blur itself, the preview only outlines it).
    fileprivate func draftAnnotation(final: Bool = false) -> Annotation? {
        guard let d = drawing, let e = d.points.last else { return nil }
        let k = editingScale
        let box = CGRect.spanning(d.start, e)
        let big = box.width > 3 * k || box.height > 3 * k
        let made: Annotation?
        switch tools.tool {
        case .rect: made = big ? Annotation(.rect(box)) : nil
        case .ellipse: made = big ? Annotation(.ellipse(box)) : nil
        case .line: made = big ? Annotation(.line(d.start, e)) : nil
        case .arrow: made = big ? Annotation(.arrow(d.start, e)) : nil
        case .pen: made = d.points.count > 1 ? Annotation(.pen(d.points)) : nil
        case .highlighter: made = d.points.count > 1 ? Annotation(.highlighter(d.points)) : nil
        case .mosaic: made = !big ? nil : final ? Annotation(.mosaic(box, block: 8)) : Annotation(.rect(box), color: .white, lineWidth: 1.5 * k)
        case .blur: made = !big ? nil : final ? Annotation(.blur(box, radius: 8)) : Annotation(.rect(box), color: .white, lineWidth: 1.5 * k)
        default: made = nil
        }
        guard let m = made else { return nil }
        if !final, tools.tool == .mosaic || tools.tool == .blur { return m }
        return styled(m)
    }

    // MARK: Drawing the document on screen (display-pixel space)

    fileprivate func drawEditingOverlays(in ctx: CGContext) {
        let k = editingScale
        let color = AppSettings.shared.selectionNSColor.cgColor
        if let draft = draftAnnotation() { Renderer.draw(draft, in: ctx) }
        ctx.setStrokeColor(color); ctx.setLineWidth(1.5 * k); ctx.setLineDash(phase: 0, lengths: [6 * k, 4 * k])
        if textField != nil {
            ctx.stroke(editRect)
            ctx.setLineDash(phase: 0, lengths: [])
            for h in [Handle.topLeft, .topRight, .bottomLeft, .bottomRight, .left, .right] {
                let q = h.point(in: editRect)
                let box = CGRect(x: q.x - 4 * k, y: q.y - 4 * k, width: 8 * k, height: 8 * k)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box); ctx.stroke(box)
            }
            ctx.setLineDash(phase: 0, lengths: [6 * k, 4 * k])
        }
        if let id = selectedID, let b = doc?.annotation(id)?.bounds { ctx.stroke(b.insetBy(dx: -4 * k, dy: -4 * k)) }
        if let m = marquee {
            ctx.stroke(m)
            if tools.tool == .select {
                ctx.setLineDash(phase: 0, lengths: [])
                for h in Handle.allCases {
                    let q = h.point(in: m), box = CGRect(x: q.x - 4 * k, y: q.y - 4 * k, width: 8 * k, height: 8 * k)
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box); ctx.stroke(box)
                }
                ctx.setLineDash(phase: 0, lengths: [6 * k, 4 * k])
            }
        }
        if let id = selectedID, let a = doc?.annotation(id), matches(a, tools.tool) {
            ctx.setLineDash(phase: 0, lengths: [])
            for (_, pt) in a.handles {
                let box = CGRect(x: pt.x - 4 * k, y: pt.y - 4 * k, width: 8 * k, height: 8 * k)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box); ctx.stroke(box)
            }
            ctx.setLineDash(phase: 0, lengths: [6 * k, 4 * k])
        }
        if let p = doc?.patch {
            ctx.stroke(p.rect)
            ctx.setLineDash(phase: 0, lengths: [])
            for h in Handle.allCases {
                let q = h.point(in: p.rect), box = CGRect(x: q.x - 4 * k, y: q.y - 4 * k, width: 8 * k, height: 8 * k)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box); ctx.stroke(box)
            }
        }
    }

    // MARK: Text

    private enum TextBoxHit { case resize(Handle), move }
    private func textBoxHit(_ p: CGPoint) -> TextBoxHit? {
        let slop = 8 * editingScale
        for h in [Handle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let q = h.point(in: editRect)
            if abs(p.x - q.x) <= slop && abs(p.y - q.y) <= slop { return .resize(h) }
        }
        if (editRect.minY - slop...editRect.maxY + slop).contains(p.y) {
            if abs(p.x - editRect.minX) <= slop { return .resize(.left) }
            if abs(p.x - editRect.maxX) <= slop { return .resize(.right) }
        }
        return editRect.insetBy(dx: -14 * editingScale, dy: -14 * editingScale).contains(p) ? .move : nil
    }

    private func layoutTextBox() {
        guard let field = textField else { return }
        let font = tools.fontName.isEmpty ? nil : tools.fontName
        let natural = Renderer.textSize(field.string, fontSize: editFont, fontName: font).width + 16 * editingScale
        let inner = editWidth ?? max(40 * editingScale, natural)
        editWrap = editWidth != nil && natural > inner ? inner : nil
        let height = Renderer.textSize(field.string, fontSize: editFont, width: editWrap, fontName: font).height
        editRect.size = CGSize(width: inner + 2 * editPad, height: max(editFont * 1.25, height) + 2 * editPad)
    }

    private func syncTextField() {
        guard let field = textField else { return }
        let inner = editRect.insetBy(dx: editPad, dy: editPad), origin = viewPoint(inner.origin)
        field.frame = CGRect(x: origin.x, y: origin.y, width: inner.width / editingScale, height: inner.height / editingScale)
        field.font = Renderer.textFont(name: tools.fontName.isEmpty ? nil : tools.fontName, size: editFont / editingScale)
        field.textContainer?.widthTracksTextView = editWrap != nil
        field.textContainer?.containerSize = NSSize(width: editWrap == nil ? 10_000_000 : field.frame.width, height: 10_000_000)
        window?.invalidateCursorRects(for: self)
    }

    fileprivate func beginText(at p: CGPoint, existing: Annotation? = nil) {
        finishText(commit: true)
        var prefill = ""
        var origin = displayPixel(p)
        editFont = tools.fontSize * editingScale; editWidth = nil; editWrap = nil
        if let a = existing, case .text(let t, let o, let fs) = a.kind, let d = doc {
            // re-edit: take the text off the picture, adopt its style, and put it back if the edit is cancelled
            selectedID = nil
            d.hiddenAnnotationID = a.id
            editingOriginal = a
            tools.color = a.color
            tools.fontName = a.fontName ?? ""
            tools.fontSize = fs / editingScale
            prefill = t; origin = o
            editFont = fs; editWidth = a.textFixedWidth ?? a.boxWidth
            refreshPreview()
        }
        editRect = CGRect(x: origin.x - editPad, y: origin.y - editPad, width: 40 * editingScale, height: editFont * 1.25 + 2 * editPad)
        let f = NSTextView(frame: .zero)
        f.isRichText = false; f.importsGraphics = false; f.allowsUndo = true
        f.drawsBackground = true; f.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        f.textContainerInset = .zero; f.textContainer?.lineFragmentPadding = 0
        f.textColor = tools.color.nsColor
        f.string = prefill
        f.delegate = self
        addSubview(f); textField = f
        layoutTextBox(); syncTextField(); needsDisplay = true
        window?.makeFirstResponder(f)
    }

    fileprivate func finishText(commit: Bool) {
        guard let f = textField else { return }
        textField = nil
        let text = f.string
        f.delegate = nil; f.removeFromSuperview()
        window?.makeFirstResponder(self)
        let original = editingOriginal
        editingOriginal = nil
        doc?.hiddenAnnotationID = nil
        guard commit, !text.isEmpty else {
            if let original { selectedID = original.id; refreshPreview() }
            needsDisplay = true; return
        }
        var a = original ?? Annotation(.text(text, origin: .zero, fontSize: editFont), color: tools.color)
        a.kind = .text(text, origin: CGPoint(x: editRect.minX + editPad, y: editRect.minY + editPad), fontSize: editFont)
        a.color = tools.color; a.fontName = tools.fontName.isEmpty ? nil : tools.fontName
        a.boxWidth = editWrap; a.textFixedWidth = editWidth; a.textAreaWidth = max(40 * editingScale, editRect.width - 2 * editPad)
        if original != nil { ensureDoc().replaceAnnotation(a, record: true) }
        else { ensureDoc().add(a) }
        selectedID = a.id
        refreshPreview()
    }

    /// Hairlines across the whole screen through the cursor.
    fileprivate func drawGuides() {
        guard let c = cursor else { return }
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: 0, y: c.y)); path.line(to: CGPoint(x: bounds.maxX, y: c.y))
        path.move(to: CGPoint(x: c.x, y: 0)); path.line(to: CGPoint(x: c.x, y: bounds.maxY))
        AppSettings.shared.selectionNSColor.withAlphaComponent(0.6).setStroke()
        path.stroke()
    }

    fileprivate func drawMagnifier() {
        guard let ctx = NSGraphicsContext.current?.cgContext, let c = cursor else { return }
        let k = editingScale
        let px = CGPoint(x: c.x * k, y: c.y * k)
        var info = "\(Int(px.x)), \(Int(px.y))"
        if let s = selection { info += "   \(Int(s.width * k))×\(Int(s.height * k))" }
        Magnifier.draw(in: ctx, image: shot.image, pixel: px, cursor: c, bounds: bounds, info: info)
    }
}

@MainActor
final class CaptureOverlay {
    static let shared = CaptureOverlay()
    private var windows: [NSWindow] = []
    private var completion: (() -> Void)?
    private var keyMonitor: Any?
    /// Return while a region is picked.
    var onConfirm: () -> Void = {}

    let tools = QuickToolState()
    var isShowingSharedResult: Bool { views.contains { $0.hasSelection && $0.isShowingSharedResult } }
    var selectedScreenRect: CGRect? { views.first(where: { $0.hasSelection })?.selectedScreenRect }

    @discardableResult func showSharedResult(_ image: CGImage) -> Bool {
        guard let view = views.first(where: { $0.hasSelection }) else { return false }
        view.showSharedResult(image)
        return true
    }

    /// The picked region with the annotations drawn so far; nil when nothing was drawn.
    func annotatedImage() -> CGImage? {
        views.forEach { $0.finishText(commit: true) }
        return views.lazy.compactMap { $0.hasSelection ? $0.annotatedImage : nil }.first
    }

    /// Keys that only matter while a region is picked: 1 / 2 change the stroke width, ⌘C / ⌘V / ⌘Z work on the drawn objects,
    /// Delete removes the selected one.
    private func handleAnnotationKey(_ e: NSEvent) -> Bool {
        guard let view = views.first(where: { $0.hasSelection }) else { return false }
        let key = e.charactersIgnoringModifiers?.lowercased()
        if e.modifierFlags.contains(.command) {
            switch key {
            case "c": tools.copy(); return true
            case "x": tools.cut(); return true
            case "a": view.selectAllInRegion(); return true
            case "v": tools.paste(); return true
            case "z": if e.modifierFlags.contains(.shift) { view.redo() } else { view.undo() }; return true
            default: return false
            }
        }
        switch key {
        case "1": tools.adjustWidth(-1); return true
        case "2": tools.adjustWidth(1); return true
        default: break
        }
        if e.keyCode == 51 || e.keyCode == 117, view.hasSelectedObject { view.deleteSelected(); return true }
        if (123...126).contains(e.keyCode) {
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = e.keyCode == 123 ? -step : e.keyCode == 124 ? step : 0
            let dy: CGFloat = e.keyCode == 126 ? -step : e.keyCode == 125 ? step : 0
            if view.nudgePatch(dx: dx * view.pixelScale, dy: dy * view.pixelScale) { return true }
        }
        return false
    }

    var isActive: Bool { !windows.isEmpty }
    private var views: [OverlayView] { windows.compactMap { $0.contentView as? OverlayView } }

    func begin(shots: [ScreenShot], windows infos: [WindowInfo], ownRegions: [CGRect] = [],
               onSelect: @escaping (CaptureResult) -> Void, onClear: @escaping () -> Void, completion: @escaping () -> Void) {
        guard !isActive else { return }
        self.completion = completion
        for shot in shots {
            let w = OverlayWindow(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: shot.screen)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.title = "Hoot 截图"
            w.isOpaque = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.setFrame(shot.screen.frame, display: false)
            let view = OverlayView(shot: shot, windows: infos, ownRegions: ownRegions, tools: tools)
            view.onSelect = { [weak self, weak view] result in
                self?.views.filter { $0 !== view }.forEach { $0.clearSelection() }   // one region at a time across displays
                onSelect(result)
            }
            view.onClear = onClear
            view.onPresentationChange = { QuickBar.reposition(around: $0) }
            view.onCancel = { [weak self] in self?.end() }
            w.contentView = view
            windows.append(w)
        }
        // Esc / Return work even when the key window / first responder is not the overlay view
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isActive else { return e }
            if QuickBar.isTrackingMenu { return e } // Menus own arrows, Return and Escape while open.
            if self.tools.isProcessing {
                if e.keyCode == 53 { self.tools.cancelProcessing() }
                if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { return e }
                return nil
            }
            if self.views.contains(where: { $0.isEditingText }) { return e }      // typing text: the field editor owns the keys
            if self.handleAnnotationKey(e) { return nil }
            if e.keyCode == 53 { self.escape(onClear); return nil }
            if e.keyCode == 36 || e.keyCode == 76 {
                if self.views.contains(where: { $0.hasSelection }) { self.onConfirm() }
                else { (self.views.first { $0.window?.frame.contains(NSEvent.mouseLocation) == true } ?? self.views.first)?.commitHover() }
                return nil
            }
            return e
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView); (w.contentView as? OverlayView)?.startDetection() }
        // Keyboard events belong to the display under the pointer, not always the last screen.
        if let w = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView) }
    }

    /// Esc takes back a picked region first; with nothing picked it leaves the capture.
    private func escape(_ onClear: () -> Void) {
        if let v = views.first(where: { $0.hasSelection }) {
            if v.softEscape() { return }
            views.forEach { $0.clearSelection() }; onClear()
        }
        else { end() }
    }

    /// Closes the overlay (after an action, or on cancel).
    func end() {
        guard isActive else { return }
        let done = completion
        completion = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows.removeAll()
        done?()
    }
}
