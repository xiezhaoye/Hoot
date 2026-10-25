import AppKit

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
    private let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

    init(shot: ScreenShot, windows: [WindowInfo]) {
        self.shot = shot
        self.windows = windows
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// Screen-local point (top-left origin) -> global top-left coordinates.
    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: shot.screen.frame.minX + p.x, y: primaryHeight - shot.screen.frame.maxY + p.y)
    }

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -shot.screen.frame.minX, dy: -(primaryHeight - shot.screen.frame.maxY))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        let g = global(convert(event.locationInWindow, from: nil))
        hover = windows.first { $0.rect.contains(g) }.map { local($0.rect).intersection(bounds) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y)).intersection(bounds)
        hover = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        let rect: CGRect?
        if let s = selection, s.width >= 4, s.height >= 4 { rect = s } else { rect = hover }
        guard let r = rect, r.width >= 2, r.height >= 2 else { selection = nil; needsDisplay = true; return }
        let k = shot.scale
        let px = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k).integral
        guard let cropped = shot.image.cropping(to: px) else { onFinish(nil); return }
        let f = shot.screen.frame
        onFinish(CaptureResult(image: cropped, screenRect: CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }
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
        r.clip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        (selection != nil ? AppSettings.shared.selectionNSColor : NSColor.systemGreen).setStroke()
        path.stroke()
        let k = shot.scale
        let label = " \(Int(r.width * k)) × \(Int(r.height * k)) " as NSString
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

    func begin(shots: [ScreenShot], windows infos: [WindowInfo], completion: @escaping (CaptureResult?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        for shot in shots {
            let w = OverlayWindow(contentRect: shot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: shot.screen)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.isOpaque = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.setFrame(shot.screen.frame, display: false)
            let view = OverlayView(shot: shot, windows: infos)
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
        for w in windows { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView) }
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
