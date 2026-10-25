import AppKit

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A screenshot pinned above everything: drag to move, scroll to zoom, double-click or Esc to close.
private final class PinView: NSView {
    let image: CGImage
    private let basePoints: CGSize

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        basePoints = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        super.init(frame: CGRect(origin: .zero, size: basePoints))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.close() } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.close() } else { super.keyDown(with: event) }
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

    @objc private func copyImage() { Clipboard.write(image) }
    @objc private func setAlpha(_ s: NSMenuItem) { window?.alphaValue = CGFloat(s.representedObject as? Double ?? 1) }
    @objc private func closeWindow() { window?.close() }
}

enum PinWindow {
    private static var open: [NSPanel] = []

    @MainActor
    static func show(_ image: CGImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let view = PinView(image: image, scale: scale)
        let panel = PinPanel(contentRect: CGRect(origin: .zero, size: view.frame.size), styleMask: [.borderless, .resizable],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: mouse.x - view.frame.width / 2, y: mouse.y - view.frame.height / 2))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            open.removeAll { $0 === panel }
        }
        open.append(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }
}
