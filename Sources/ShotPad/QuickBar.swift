import AppKit
import SwiftUI

struct QuickActions {
    var copyText: (@escaping (String) -> Void) -> Void
    var translate: () -> Void
    var edit: () -> Void
    var copyImage: () -> Void
    var pin: () -> Void
    var close: () -> Void
}

private struct QuickBarView: View {
    let actions: QuickActions
    @State private var status = ""

    var body: some View {
        HStack(spacing: 4) {
            barButton("text.viewfinder", "复制文字") {
                status = "识别中…"
                actions.copyText { status = $0 }
            }
            barButton("character.bubble", "翻译") { actions.translate() }
            barButton("pencil.and.outline", "编辑") { actions.edit() }
            Divider().frame(height: 18)
            barButton("doc.on.doc", "复制") { actions.copyImage(); status = "已复制图片" }
            barButton("pin", "贴图") { actions.pin() }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
            Button { actions.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("关闭")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.35)))
        .padding(2)
    }

    private func barButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.titleAndIcon) }
            .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 4)
    }
}

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Floating bar shown under a fresh capture.
@MainActor
enum QuickBar {
    private static var panel: NSPanel?

    static func show(near rect: CGRect, actions: QuickActions) {
        dismiss()
        let host = NSHostingView(rootView: QuickBarView(actions: actions))
        let size = host.fittingSize
        let p = BarPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < vis.minY { origin.y = rect.maxY + 8 }
        if origin.y + size.height > vis.maxY { origin.y = max(vis.minY, rect.minY + 8) }
        origin.x = max(vis.minX + 4, min(origin.x, vis.maxX - size.width - 4))
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        panel = p
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
