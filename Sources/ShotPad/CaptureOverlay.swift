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
fileprivate final class OverlayView: NSView {
    let shot: ScreenShot
    let windows: [WindowInfo]
    var onFinish: (CaptureResult?) -> Void = { _ in }
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

    init(shot: ScreenShot, windows: [WindowInfo], ownRegions: [CGRect]) {
        self.shot = shot
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
        guard let cursor, dragStart == nil else { return }
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
        guard dragStart == nil, !candidates.isEmpty else { return }
        userChoseCandidate = true
        candidateIndex = (candidateIndex + delta + candidates.count) % candidates.count
        hover = local(candidates[candidateIndex]).intersection(bounds); updateAccessibilityLabel(); needsDisplay = true
    }
    private func pixelRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * shot.scale, y: r.minY * shot.scale, width: r.width * shot.scale, height: r.height * shot.scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
    }
    private func updateAccessibilityLabel() {
        guard let r = selection ?? hover, !r.isNull else { return }
        let px = pixelRect(r)
        let mode = selection != nil ? "手动选区" : "截图选区"
        setAccessibilityLabel("\(mode) \(Int(px.width)) × \(Int(px.height)) 像素，范围 \(candidateIndex + 1)/\(candidates.count)，Tab 切换，回车截图，Esc 取消")
    }
    override func scrollWheel(with event: NSEvent) {
        wheelTotal += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 16 : 1
        if abs(wheelTotal) >= threshold { cycleTarget(wheelTotal > 0 ? 1 : -1); wheelTotal = 0 }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// Screen-local point (top-left origin) -> global top-left coordinates.
    private func global(_ p: CGPoint) -> CGPoint {
        CaptureGeometry.global(p, screen: shot.screen.frame, primaryHeight: primaryHeight)
    }

    private func local(_ r: CGRect) -> CGRect {
        CaptureGeometry.local(r, screen: shot.screen.frame, primaryHeight: primaryHeight)
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        userChoseCandidate = false
        updateTarget()
    }

    override func mouseDown(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        updateTarget(preserveSelection: true, query: false)
        dragStart = cursor
        queryGeneration += 1; resolver.cancel()
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)).intersection(bounds)
        hover = nil
        updateAccessibilityLabel(); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        let rect: CGRect?
        if let s = selection, s.width >= 4, s.height >= 4 { rect = s } else { rect = hover }
        accept(rect)
    }

    private func accept(_ rect: CGRect?) {
        guard let r = rect, r.width >= 2, r.height >= 2 else { selection = nil; needsDisplay = true; return }
        let px = pixelRect(r)
        guard let cropped = shot.image.cropping(to: px) else { onFinish(nil); return }
        let f = shot.screen.frame
        onFinish(CaptureResult(image: CaptureGeometry.rounded(cropped, radius: cornerRadius), screenRect: CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) }
        else if event.keyCode == 36 || event.keyCode == 76 { accept(selection ?? hover) }
        else if event.keyCode == 48 { cycleTarget(event.modifierFlags.contains(.shift) ? -1 : 1) }
        else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) { onFinish(nil) }

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: shot.image, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill(using: .sourceOver)
        defer { drawGuides(); drawMagnifier() }
        guard let r = selection ?? hover else { return }
        NSGraphicsContext.saveGraphicsState()
        let radius = min(cornerRadius / shot.scale, min(r.width, r.height) / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        path.lineWidth = 2
        (selection != nil ? AppSettings.shared.selectionNSColor : NSColor.systemGreen).setStroke()
        path.stroke()
        let label = " \(Int(pixelRect(r).width)) × \(Int(pixelRect(r).height))\(selection == nil && candidates.count > 1 ? " · 滚轮 / Tab 切换范围" : "") " as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.white,
                                                    .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: r.minX, y: r.minY >= size.height + 4 ? r.minY - size.height - 4 : r.minY + 4), withAttributes: attrs)
    }
}

extension OverlayView {
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
        let k = shot.scale
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
    private var completion: ((CaptureResult?) -> Void)?
    private var keyMonitor: Any?

    var isActive: Bool { !windows.isEmpty }

    func begin(shots: [ScreenShot], windows infos: [WindowInfo], ownRegions: [CGRect] = [], completion: @escaping (CaptureResult?) -> Void) {
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
            let view = OverlayView(shot: shot, windows: infos, ownRegions: ownRegions)
            view.onFinish = { [weak self] image in self?.finish(image) }
            w.contentView = view
            windows.append(w)
        }
        // Esc cancels even when the key window / first responder is not the overlay view
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(nil); return nil }
            return e
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView); (w.contentView as? OverlayView)?.startDetection() }
        // Keyboard events belong to the display under the pointer, not always the last screen.
        if let w = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView) }
    }

    private func finish(_ image: CaptureResult?) {
        let done = completion
        completion = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows.removeAll()
        done?(image)
    }
}
