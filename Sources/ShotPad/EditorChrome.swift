import AppKit
import SwiftUI
import ShotPadCore

enum EditorStyle {
    static let brandLockup: NSImage? = {
        guard let url = Bundle.main.url(forResource: "brand-lockup", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()
    static let footerHeight: CGFloat = 36
    static let sidebarWidth: CGFloat = 224
    static let inspectorWidth: CGFloat = 228
    static let separator = Color.primary.opacity(0.10)
    static let nsAccent = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
    static let accent = Color(nsColor: nsAccent)
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(srgbRed: 0.973, green: 0.973, blue: 0.98, alpha: 1)
    })
    static let well = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.12, alpha: 1) : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.941, alpha: 1)
    })
}

struct EditorIconButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, selected: selected)
    }
    private struct IconBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size: 15))
                .foregroundStyle(selected ? EditorStyle.accent : Color.primary.opacity(0.68))
                .frame(width: 32, height: 30)
                .background(selected ? EditorStyle.accent.opacity(0.13) : Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6)).onHover { hovering = $0 }
                .opacity(enabled ? 1 : 0.32)
        }
    }
}

struct EditorHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 32)
            .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension Tool {
    var title: String {
        switch self {
        case .hand: "移动"; case .select: "选区"; case .rect: "矩形"; case .ellipse: "椭圆"
        case .line: "直线"; case .arrow: "箭头"; case .pen: "画笔"; case .highlighter: "荧光笔"
        case .mosaic: "马赛克"; case .blur: "模糊"; case .text: "文字"; case .number: "序号"; case .crop: "裁剪"
        }
    }
    var symbol: String {
        switch self {
        case .hand: "cursorarrow"; case .select: "rectangle.dashed"; case .rect: "rectangle"; case .ellipse: "circle"
        case .line: "line.diagonal"; case .arrow: "arrow.up.right"; case .pen: "pencil.tip"; case .highlighter: "highlighter"
        case .mosaic: "squareshape.split.3x3"; case .blur: "drop"; case .text: "textformat"; case .number: "1.circle"; case .crop: "crop"
        }
    }
    var usesColor: Bool { ![.hand, .select, .crop, .mosaic, .blur].contains(self) }
    var usesWidth: Bool { [.rect, .ellipse, .line, .arrow, .pen, .highlighter, .number, .mosaic, .blur].contains(self) }
    var hint: String {
        switch self {
        case .hand: "拖动画布以移动，捏合以缩放"
        case .select: "框选区域后复制、粘贴或拖动移动"
        case .crop: "拖动控制点调整裁剪范围，回车裁剪并复制"
        case .text: "点击输入文字，拖四角缩放字号，拖两侧调整宽度"
        case .number: "点击添加序号，拖动手柄调整大小"
        case .pen, .highlighter: "按住并拖动，自由绘制\(title)"
        case .mosaic, .blur: "拖动框选需要\(title)处理的区域"
        default: "拖动绘制\(title)，点击已有标注可再次编辑"
        }
    }
}

struct EditorMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
