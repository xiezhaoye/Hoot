import AppKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Full-screen frozen screenshot on one display; the user drags a region or clicks a hovered window.
private final class OverlayView: NSView {
    let shot: ScreenShot
    let windows: [WindowInfo]
    var onFinish: (CGImage?) -> Void = { _ in }
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
        onFinish(shot.image.cropping(to: px))
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
        guard let r = selection ?? hover else { return }
        NSGraphicsContext.saveGraphicsState()
        r.clip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        (selection != nil ? NSColor.systemBlue : NSColor.systemGreen).setStroke()
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

@MainActor
final class CaptureOverlay {
    static let shared = CaptureOverlay()
    private var windows: [NSWindow] = []
    private var completion: ((CGImage?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func begin(shots: [ScreenShot], windows infos: [WindowInfo], completion: @escaping (CGImage?) -> Void) {
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
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView) }
    }

    private func finish(_ image: CGImage?) {
        let done = completion
        completion = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        done?(image)
    }
}
