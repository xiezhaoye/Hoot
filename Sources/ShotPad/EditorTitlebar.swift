import AppKit
import SwiftUI

/// Reuses AppKit's actual window controls; only their position is customized.
struct EditorTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) { view.layoutButtons() }
    final class Host: NSView {
        private var buttons: [NSButton] = []
        private var resizeObserver: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, buttons.isEmpty else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(type) { buttons.append(button) }
            }
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutButtons() }
            }
            layoutButtons()
        }
        override func layout() { super.layout(); layoutButtons() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutButtons() }
        func layoutButtons() {
            for (index, button) in buttons.enumerated() {
                guard let parent = button.superview else { continue }
                button.isHidden = false
                let point = convert(NSPoint(x: 20 + CGFloat(index) * 20, y: (bounds.height - button.frame.height) / 2), to: parent)
                button.setFrameOrigin(point)
            }
        }
        deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }
    }
}

struct EditorWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}
