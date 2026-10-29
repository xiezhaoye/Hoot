import AppKit
import ShotPadCore

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A screenshot pinned above everything: drag to move, scroll to zoom, double-click or Esc to close.
/// Draws like the capture overlay: the same tool bar above and action bar below, and the drawing lives in an editor document.
private final class PinView: NSView {
    let baseImage: CGImage
    let tools: QuickToolState
    private let basePoints: CGSize
    private var doc: EditorDocument?
    private var shown: CGImage
    private var drawing: (start: CGPoint, points: [CGPoint])?
    var onChange: () -> Void = {}

    init(image: CGImage, scale: CGFloat, tools: QuickToolState) {
        baseImage = image; shown = image; self.tools = tools
        basePoints = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        super.init(frame: CGRect(origin: .zero, size: basePoints))
        tools.undo = { [weak self] in self?.undo() }
        tools.onStyle = { [weak self] in self?.restyleLast() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Picture pixels per view point.
    private var factor: CGFloat { CGFloat(baseImage.width) / max(1, bounds.width) }
    /// Picture pixels per point at 100 % (strokes keep their look when zoomed).
    private var unit: CGFloat { CGFloat(baseImage.width) / basePoints.width }
    var current: CGImage { shown }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { tools.tool == .hand }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { if tools.tool != .hand { addCursorRect(bounds, cursor: .crosshair) } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(shown, in: bounds)
        ctx.restoreGState()
        if let draft = draftAnnotation() {
            ctx.saveGState(); ctx.scaleBy(x: 1 / factor, y: 1 / factor)
            Renderer.draw(draft, in: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: Drawing

    private func pixel(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let f = factor
        return CGPoint(x: min(max(0, p.x * f), CGFloat(baseImage.width)), y: min(max(0, p.y * f), CGFloat(baseImage.height)))
    }

    private func styled(_ a: Annotation) -> Annotation {
        var a = a
        let k = unit, w = tools.width
        a.color = tools.color
        switch a.kind {
        case .highlighter: a.lineWidth = w * k * 8 / 3
        case .number(let n, let c, _): a.kind = .number(n, center: c, diameter: (16 + w * 4) * k)
        case .mosaic(let r, _): a.kind = .mosaic(r, block: Int(max(4, w * 2.7 * k)))
        case .blur(let r, _): a.kind = .blur(r, radius: Double(w * 3.3 * k))
        default: a.lineWidth = w * k
        }
        return a
    }

    private func draftAnnotation(final: Bool = false) -> Annotation? {
        guard let d = drawing, let e = d.points.last else { return nil }
        let k = unit
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

    private func ensureDoc() -> EditorDocument {
        if let d = doc { return d }
        let d = EditorDocument(image: baseImage); doc = d; return d
    }

    private func refresh() {
        shown = doc.map { $0.isModified ? $0.composite() : baseImage } ?? baseImage
        tools.canUndo = doc?.canUndo ?? false
        needsDisplay = true; onChange()
    }

    private func undo() { guard let d = doc, d.canUndo else { return }; d.undo(); refresh() }

    /// Colour / width changes apply to the drawing just made, like the capture overlay.
    private var lastID: UUID?
    private func restyleLast() {
        guard let d = doc, let id = lastID, let a = d.annotation(id) else { return }
        d.replaceAnnotation(styled(a), record: true); refresh()
    }

    private func constrained(_ end: CGPoint, from start: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return end }
        let limit = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        switch tools.tool {
        case .rect, .ellipse: return DrawingGeometry.squareEndpoint(from: start, to: end, within: limit)
        case .line, .arrow: return DrawingGeometry.snappedEndpoint(from: start, to: end, within: limit)
        default: return end
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && tools.tool == .hand { window?.close(); return }
        guard tools.tool != .hand else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let p = pixel(event)
        if tools.tool == .number {
            let d = ensureDoc()
            let a = styled(Annotation(.number(d.nextNumber(), center: p, diameter: 0)))
            d.add(a); lastID = a.id; refresh()
        } else if tools.tool != .text, tools.tool != .select { drawing = (p, [p]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drawing else { return }
        let end = constrained(pixel(event), from: d.start, shift: event.modifierFlags.contains(.shift))
        if tools.tool == .pen || tools.tool == .highlighter { drawing?.points.append(end) } else { drawing?.points = [d.start, end] }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard drawing != nil else { return }
        if let a = draftAnnotation(final: true) { ensureDoc().add(a); lastID = a.id }
        drawing = nil; refresh()
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (53, _): window?.close()
        case (_, "z") where cmd: undo()
        case (_, "c") where cmd: Clipboard.write(shown)
        case (_, "1") where !cmd: tools.adjustWidth(-1)
        case (_, "2") where !cmd: tools.adjustWidth(1)
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let w = window else { return }
        let factor = 1 + event.scrollingDeltaY * 0.01
        let ratio = max(0.1, min(8, w.frame.width / basePoints.width * factor))
        let size = CGSize(width: basePoints.width * ratio, height: basePoints.height * ratio)
        let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height), display: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "").target = self
        for (title, alpha) in [("透明度 100%", 1.0), ("透明度 70%", 0.7), ("透明度 40%", 0.4)] {
            let item = m.addItem(withTitle: title, action: #selector(setAlpha(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = alpha
        }
        m.addItem(withTitle: "关闭", action: #selector(closeWindow), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyImage() { Clipboard.write(shown) }
    @objc private func setAlpha(_ s: NSMenuItem) { window?.alphaValue = CGFloat(s.representedObject as? Double ?? 1) }
    @objc private func closeWindow() { window?.close() }
}

enum PinWindow {
    private static var open: [NSPanel] = []
    /// Set by the app: files the pinned picture in the history and opens it in the editor.
    @MainActor static var onEdit: ((CGImage) -> Void)?

    @MainActor
    static func show(_ image: CGImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let tools = QuickToolState()
        tools.showsReselect = false
        tools.available = QuickToolState.tools.filter { $0 != .select && $0 != .text }
        let view = PinView(image: image, scale: scale, tools: tools)
        let panel = PinPanel(contentRect: CGRect(origin: .zero, size: view.frame.size), styleMask: [.borderless, .resizable],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false   // stay on screen when another app (or a new capture) is in front
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: mouse.x - view.frame.width / 2, y: mouse.y - view.frame.height / 2))

        let close: () -> Void = { [weak panel] in panel?.close() }
        let actions = QuickActions(
            copyText: { report in
                let img = view.current
                Task { @MainActor in
                    do {
                        let text = try await TextTools.extractText(img)
                        if text.isEmpty { report("没有识别到文字"); return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        report("已复制 \(text.count) 字")
                    } catch { report("识别失败") }
                }
            },
            openURL: { _ in
                let img = view.current
                Task { @MainActor in if let url = await TextTools.findURL(img) { NSWorkspace.shared.open(url) } else { NSSound.beep() } }
            },
            translate: { TextTools.showTranslation(view.current, toChinese: nil) { _ in } },
            edit: { onEdit?(view.current); close() },
            copyImage: { Clipboard.write(view.current) },
            pin: { PinWindow.show(view.current) },
            close: close,
            dismissAfterAction: false)
        let bars = QuickBar.makePinBars(tools: tools, actions: actions)
        let place = { [weak panel] in
            guard let panel else { return }
            QuickBar.layout(tools: bars.tools, actions: bars.actions, around: panel.frame)
        }
        view.onChange = { panel.invalidateCursorRects(for: view) }
        tools.onToolChange = { [weak panel] in panel?.invalidateCursorRects(for: view) }
        place()
        panel.addChildWindow(bars.tools, ordered: .above)
        panel.addChildWindow(bars.actions, ordered: .above)
        let resize = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { place() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.removeObserver(resize)
                bars.tools.orderOut(nil); bars.actions.orderOut(nil)
                open.removeAll { $0 === panel }
            }
        }
        open.append(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }
}
