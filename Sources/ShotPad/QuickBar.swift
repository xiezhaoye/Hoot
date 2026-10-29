import AppKit
import SwiftUI
import ShotPadCore

typealias PhoneShareAction = @MainActor (@escaping @MainActor (String) -> Void) async throws -> Void

struct QuickActions {
    var copyText: (@escaping (String) -> Void) -> Void
    var openURL: (@escaping (String) -> Void) -> Void
    var translate: () -> Void
    var edit: () -> Void
    var copyImage: () -> Void
    var shareImage: (() -> Bool)? = nil
    var shareForPhone: PhoneShareAction? = nil
    var pin: () -> Void
    var close: () -> Void
    /// Capture bars disappear after an action; a pinned shot stays.
    var dismissAfterAction = true
    var dismissAfterShare = true
}

/// Annotation tool state shared between the bars and the capture overlay.
@MainActor
final class QuickToolState: ObservableObject {
    /// `.hand` = no drawing tool: the selection (or a drawn object) can be moved and resized.
    @Published var tool: Tool = .hand {
        didSet {
            guard tool != oldValue else { return }
            styles[oldValue] = (color, width, fontName, fontSize)
            onToolChange()
            if let style = styles[tool] {
                restoringStyle = true
                color = style.color; width = style.width; fontName = style.font; fontSize = style.size
                restoringStyle = false
            }
        }
    }
    @Published var color = RGBA.red { didSet { if color != oldValue && !restoringStyle { onStyle() } } }
    /// Stroke width in points; text size, number size and mosaic strength follow it.
    @Published var width: CGFloat = 3 { didSet { if width != oldValue && !restoringStyle { onStyle() } } }
    @Published var fontName = "" { didSet { if fontName != oldValue && !restoringStyle { onStyle() } } }
    @Published var fontSize: CGFloat = 19 { didSet { if fontSize != oldValue && !restoringStyle { onStyle() } } }
    private var styles: [Tool: (color: RGBA, width: CGFloat, font: String, size: CGFloat)] = [:]
    private var restoringStyle = false
    @Published var canUndo = false
    @Published private(set) var editStatus = ""
    private var statusID = UUID()
    @Published private(set) var processingID: UUID?
    var isProcessing: Bool { processingID != nil }
    var cancelProcessing: () -> Void = {}
    var undo: () -> Void = {}
    var reselect: () -> Void = {}
    var cut: () -> Void = {}
    var copy: () -> Void = {}
    var paste: () -> Void = {}
    var onStyle: () -> Void = {}
    var onToolChange: () -> Void = {}
    var available = QuickToolState.tools
    var showsReselect = true

    static let tools: [Tool] = [.select, .rect, .ellipse, .arrow, .line, .pen, .highlighter, .text, .number, .mosaic, .blur]
    static let colors: [RGBA] = [.red, RGBA(1, 0.8, 0), RGBA(0.2, 0.75, 0.3), RGBA(0.1, 0.45, 1), .black, .white]
    static let widthRange: ClosedRange<CGFloat> = 1...12

    func pick(_ next: Tool) { guard !isProcessing else { return }; tool = tool == next ? .hand : next }
    func adjustWidth(_ delta: CGFloat) { guard !isProcessing else { return }; width = min(max(width + delta, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
    func setFontSizeSilently(_ value: CGFloat) { restoringStyle = true; fontSize = value; restoringStyle = false }
    func loadStyle(color: RGBA, width: CGFloat, fontName: String, fontSize: CGFloat) {
        restoringStyle = true
        self.color = color; self.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        self.fontName = fontName; self.fontSize = fontSize
        restoringStyle = false
    }
    func showEditStatus(_ message: String) {
        let id = UUID(); statusID = id; editStatus = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.statusID == id { self?.editStatus = "" }
        }
    }
    func reset() { cancelProcessing(); processingID = nil; cancelProcessing = {}; tool = .hand; canUndo = false }
    func beginProcessing(_ id: UUID, cancel: @escaping () -> Void) {
        cancelProcessing(); processingID = id; cancelProcessing = cancel
    }
    func endProcessing(_ id: UUID) {
        guard processingID == id else { return }
        processingID = nil; cancelProcessing = {}
    }
}

/// The drawing tools, shown above the picked region.
struct QuickToolbarView: View {
    @ObservedObject var tools: QuickToolState

    var body: some View {
        HStack(spacing: 2) {
            if tools.showsReselect {
                Button { tools.reselect() } label: { Image(systemName: "viewfinder").frame(width: 26, height: 24) }
                    .buttonStyle(.borderless).help("重新选区")
            }
            if tools.showsReselect { Menu {
                Button("剪切") { tools.cut() }
                Button("复制") { tools.copy() }
                Button("粘贴") { tools.paste() }
            } label: { Image(systemName: "doc.on.clipboard").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().help("剪切、复制、粘贴")
            }
            toolButton(.hand, symbol: "arrow.up.left.and.arrow.down.right", title: "移动截图范围 / 选中标注（可拖动、Delete 删除）")
            ForEach(tools.available, id: \.self) { toolButton($0, symbol: $0.symbol, title: $0 == .select ? "选区：框选后 ⌘C 复制、⌘V 粘贴，拖动可移动内容" : $0.title) }
            if tools.showsReselect {
                Menu {
                    Menu("字体") {
                        Button("系统字体") { tools.fontName = "" }
                        ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                            Button(family) { tools.fontName = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: tools.fontSize)?.fontName ?? family }
                        }
                    }
                    Menu("字号") {
                        ForEach([12, 14, 16, 19, 24, 28, 36, 48, 64, 96], id: \.self) { size in
                            Button("\(size)") { tools.fontSize = CGFloat(size) }
                        }
                    }
                } label: { Image(systemName: "textformat.size").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(tools.tool != .text).help("设置文字字体和字号")
            }
            Divider().frame(height: 18).padding(.horizontal, 3)
            ForEach(QuickToolState.colors.indices, id: \.self) { i in
                let c = QuickToolState.colors[i]
                Button { tools.color = c } label: {
                    Circle().fill(Color(nsColor: c.nsColor)).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: tools.color == c ? 2 : 0).padding(-3))
                        .frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("颜色")
            }
            Divider().frame(height: 18).padding(.horizontal, 3)
            Button { tools.adjustWidth(-1) } label: { Image(systemName: "minus").font(.system(size: 11, weight: .bold)).frame(width: 18, height: 22) }
                .buttonStyle(.borderless).help("变细（键盘 1）")
            Text("\(Int(tools.width))").font(.system(size: 12, weight: .medium).monospacedDigit()).frame(minWidth: 18)
            Button { tools.adjustWidth(1) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 18, height: 22) }
                .buttonStyle(.borderless).help("变粗（键盘 2）")
            Divider().frame(height: 18).padding(.horizontal, 3)
            Button { tools.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 24) }
                .buttonStyle(.borderless).disabled(!tools.canUndo).help("撤销")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.35)))
        .overlay {
            if !tools.editStatus.isEmpty {
                Text(tools.editStatus).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
            }
        }
        .padding(2)
        .disabled(tools.isProcessing)
    }

    private func toolButton(_ tool: Tool, symbol: String, title: String) -> some View {
        Button { tools.pick(tool) } label: {
            Group {
                if tool == .text { Text("Aa").font(.system(size: 13, weight: .bold)) } else { Image(systemName: symbol) }
            }.frame(width: 26, height: 24)
                .background(tools.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.borderless).help(title)
    }
}

struct QuickBarView: View {
    let actions: QuickActions
    var tools: QuickToolState? = nil
    @State private var status = ""
    @State private var mobileTask: Task<Void, Never>?
    @State private var jobID: UUID?
    @State private var progress = ""
    @State private var cancelling = false

    var body: some View {
        Group {
            if mobileTask != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button("取消") { cancelMobileShare() }.buttonStyle(.borderless).disabled(cancelling)
                    Button { mobileTask?.cancel(); actions.close() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("关闭截图并取消处理")
                }
            } else if !status.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    Text(status).font(.system(size: 12)).lineLimit(1).help(status)
                    Spacer()
                    Button("返回") { status = "" }.buttonStyle(.borderless)
                    Button { actions.close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            } else { actionButtons }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.35)))
        .padding(2)
        .onDisappear {
            mobileTask?.cancel()
            if let jobID { tools?.endProcessing(jobID) }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            barButton("text.viewfinder", "文字") {
                // the bar closes at once; a soft sound tells whether the text reached the clipboard
                actions.copyText { msg in
                    if msg.hasPrefix("已复制") { NSSound(named: "Tink")?.play() } else { NSSound.beep() }
                }
            }.help("识别并复制截图中的文字")
            barButton("safari", "URL") { actions.openURL { _ in } }.help("打开截图中的网址或二维码链接")
            barButton("character.bubble", "翻译") { actions.translate() }
            Button { actions.edit(); if actions.dismissAfterAction { actions.close() } } label: { Label("编辑", systemImage: "pencil.and.outline").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderedProminent).controlSize(.small).help("编辑（回车）")
            Divider().frame(height: 18)
            barButton("doc.on.doc", "复制") { actions.copyImage() }
            if let share = actions.shareImage {
                Menu {
                    Button("原图（原尺寸）") {
                        if share() {
                            NSSound(named: "Tink")?.play()
                            if actions.dismissAfterShare { actions.close() }
                        } else { status = "无法生成图片，请检查默认模板设置"; NSSound.beep() }
                    }
                    if let phone = actions.shareForPhone {
                        Button("适配手机") { startMobileShare(phone) }
                    }
                } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small).padding(.horizontal, 4)
                    .help("原图保留尺寸；适配手机会识别文字并重新排版")
            }
            barButton("pin", "钉住") { actions.pin() }
            Button { actions.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("关闭")
        }
    }

    private func startMobileShare(_ action: @escaping PhoneShareAction) {
        guard mobileTask == nil else { return }
        let id = UUID(); jobID = id; status = ""; cancelling = false; progress = "正在识别文字…"
        mobileTask = Task { @MainActor in
            defer { tools?.endProcessing(id); mobileTask = nil; jobID = nil }
            do {
                try await action { message in if jobID == id && !cancelling { progress = message } }
                NSSound(named: "Tink")?.play()
                if actions.dismissAfterShare { actions.close() }
            } catch is CancellationError { status = "" }
            catch { status = error.localizedDescription; NSSound.beep() }
        }
        tools?.beginProcessing(id) { cancelMobileShare() }
    }
    private func cancelMobileShare() { cancelling = true; progress = "正在取消…"; mobileTask?.cancel() }

    private func barButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button { action(); if actions.dismissAfterAction { actions.close() } } label: { Label(title, systemImage: icon).labelStyle(.titleAndIcon) }
            .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 4)
    }
}

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Floating bars around the picked region: drawing tools above, actions below.
@MainActor
enum QuickBar {
    private static var panel: NSPanel?
    private static var toolPanel: NSPanel?
    private static var trackingDepth = 0
    private static var menuObservers: [NSObjectProtocol] = []
    static var isTrackingMenu: Bool { trackingDepth > 0 }

    private static func observeMenus() {
        guard menuObservers.isEmpty else { return }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { trackingDepth += 1 }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { trackingDepth = max(0, trackingDepth - 1) }
            }
        ]
    }

    static func makePanel<V: View>(_ view: V) -> NSPanel {
        observeMenus()
        let host = NSHostingView(rootView: view)
        let p = BarPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    static func show(near rect: CGRect, actions: QuickActions, tools: QuickToolState) {
        dismiss()
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? rect
        func clampX(_ x: CGFloat, _ w: CGFloat) -> CGFloat { max(vis.minX + 4, min(x, vis.maxX - w - 4)) }

        let bar = makePanel(QuickBarView(actions: actions, tools: tools))
        let size = bar.frame.size
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < vis.minY { origin.y = max(vis.minY, rect.minY + 8) }          // no room below: inside the bottom edge
        origin.x = clampX(origin.x, size.width)
        bar.setFrameOrigin(origin)
        bar.orderFrontRegardless()
        panel = bar

        let tp = makePanel(QuickToolbarView(tools: tools))
        let ts = tp.frame.size
        var to = CGPoint(x: rect.midX - ts.width / 2, y: rect.maxY + 8)
        if to.y + ts.height > vis.maxY { to.y = min(vis.maxY - ts.height, rect.maxY - ts.height - 8) }   // no room above: inside the top edge
        to.x = clampX(to.x, ts.width)
        tp.setFrameOrigin(to)
        tp.orderFrontRegardless()
        toolPanel = tp
    }

    /// Builds the tool bar and the action bar of a pinned shot (not tracked by `dismiss`).
    static func makePinBars(tools: QuickToolState, actions: QuickActions) -> (tools: NSPanel, actions: NSPanel) {
        (makePanel(QuickToolbarView(tools: tools)), makePanel(QuickBarView(actions: actions, tools: tools)))
    }

    /// Tool bar above `rect`, action bar below it (screen coordinates); each falls inside the edge when there is no room.
    static func layout(tools tp: NSPanel, actions bar: NSPanel, around rect: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? rect
        func clampX(_ x: CGFloat, _ w: CGFloat) -> CGFloat { max(vis.minX + 4, min(x, vis.maxX - w - 4)) }
        let size = bar.frame.size
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < vis.minY { origin.y = max(vis.minY, rect.minY + 8) }
        origin.x = clampX(origin.x, size.width)
        bar.setFrameOrigin(origin)
        let ts = tp.frame.size
        var to = CGPoint(x: rect.midX - ts.width / 2, y: rect.maxY + 8)
        if to.y + ts.height > vis.maxY { to.y = min(vis.maxY - ts.height, rect.maxY - ts.height - 8) }
        to.x = clampX(to.x, ts.width)
        tp.setFrameOrigin(to)
    }

    static func dismiss() {
        panel?.orderOut(nil); panel = nil
        toolPanel?.orderOut(nil); toolPanel = nil
    }

    static func reposition(around rect: CGRect) {
        guard let tp = toolPanel, let bar = panel else { return }
        layout(tools: tp, actions: bar, around: rect)
    }
}
