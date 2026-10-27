import AppKit
import SwiftUI
import ShotPadCore

struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> NSScrollView {
        let canvas = CanvasView(frame: .zero)
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true; scroll.backgroundColor = CanvasView.surround
        model.canvas = canvas
        DispatchQueue.main.async { canvas.attach(model) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CanvasView else { return }
        canvas.window?.invalidateCursorRects(for: canvas)
    }
}

enum SideTab: String, CaseIterable { case shots = "截图", browse = "浏览" }

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var browse = BrowseModel()
    @State private var tab: SideTab = .shots
    @State private var category: HistoryGroup? = .normal
    @State private var notice = ""
    @State private var noticeTask: Task<Void, Never>?
    @State private var directionOpen = false
    @State private var windowWidth: CGFloat = 1400

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Divider()
            workspace
        }
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            if settings.historySide == .left { historyPane; Divider() }
            GeometryReader { geometry in
            ZStack {
                editor.opacity(tab == .shots ? 1 : 0).allowsHitTesting(tab == .shots)
                if tab == .browse { BrowseDetail(model: browse, onEdit: editFromBrowse) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
            if settings.historySide == .right { Divider(); historyPane }
        }
        .tint(EditorStyle.accent)
        .onChange(of: model.status) { _, value in
            noticeTask?.cancel(); notice = value
            guard !value.isEmpty else { return }
            noticeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                notice = ""
            }
        }
        .onDisappear { noticeTask?.cancel() }
    }

    private var editor: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                markupBar
                Divider()
                CanvasRepresentable(model: model).overlay(alignment: .bottom) {
                    if !notice.isEmpty {
                        Text(notice).font(.system(size: 12)).lineLimit(3)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(EditorStyle.separator, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                            .padding(18).allowsHitTesting(false).accessibilityLabel("操作结果：\(notice)")
                    }
                }
                Divider()
                statusBar
            }.frame(minWidth: 480)
            if model.inspectorVisible {
                Divider()
                EditorInspector(model: model).frame(width: EditorStyle.inspectorWidth)
            }
        }
    }

    private var titlebar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                EditorTrafficLights().frame(width: 88, height: 47)
                Text("Hoot").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
                Spacer(minLength: 0)
            }
            .frame(width: EditorStyle.sidebarWidth, height: 47)
            .background(EditorStyle.sidebar)
            Divider()
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button { (NSApp.delegate as? AppDelegate)?.capture() } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "camera.viewfinder").font(.system(size: 20))
                            Text("截图").font(.system(size: 14, weight: .medium))
                        }.padding(.horizontal, 12).frame(height: 30)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help("截图 \(settings.captureShortcutText)").accessibilityLabel("截图")
                    EditorWindowDragArea().frame(minWidth: 6, maxWidth: .infinity, maxHeight: .infinity)
                    if tab == .shots { headerActions.fixedSize(horizontal: true, vertical: false) }
                }.padding(.horizontal, 16).frame(maxWidth: .infinity)
                Divider()
                Group {
                    if tab == .shots { outputActions }
                    else {
                        Button(action: editBrowseImage) {
                            Label("编辑图片", systemImage: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 30)
                        }.buttonStyle(.plain).foregroundStyle(.white)
                            .background(EditorStyle.accent, in: RoundedRectangle(cornerRadius: 7))
                            .disabled(browse.current == nil).opacity(browse.current == nil ? 0.4 : 1)
                            .help("送进编辑器，结果另存到“截图”，不改原文件（回车）")
                    }
                }.padding(.horizontal, 12).frame(width: settings.historySide == .right ? EditorStyle.sidebarWidth : EditorStyle.inspectorWidth)
            }.frame(maxWidth: .infinity).frame(height: 47)
                .background(EditorStyle.panel.opacity(0.7))
        }.frame(height: 47)
    }
    private func editBrowseImage() {
        guard let url = browse.current, let image = ImageLoader.loadFull(url) else { return }
        editFromBrowse(image)
    }
    private var headerActions: some View {
        HStack(spacing: 6) {
            Button { model.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(EditorIconButtonStyle()).disabled(!model.doc.canUndo).help("撤销 ⌘Z").accessibilityLabel("撤销")
            Button { model.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(EditorIconButtonStyle()).disabled(!model.doc.canRedo).help("重做 ⇧⌘Z").accessibilityLabel("重做")
            headerSeparator
            Button { model.runOCR() } label: {
                HStack(spacing: 7) { Image(systemName: "text.viewfinder").font(.system(size: 16)); if windowWidth >= 1180 { Text("识别文字").fixedSize() } }
            }.buttonStyle(EditorHeaderButtonStyle()).accessibilityLabel("识别文字").help("识别选区或整张图像中的文字")
            HStack(spacing: 0) {
                Button { model.translate() } label: {
                    HStack(spacing: 6) { Image(systemName: "translate").font(.system(size: 16)); if windowWidth >= 1180 { Text("翻译").fixedSize() } }
                }.buttonStyle(EditorHeaderButtonStyle()).accessibilityLabel("翻译").help("翻译选区或整张图像中的文字")
                Button { directionOpen.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 12, height: 30)
                }.buttonStyle(.plain).accessibilityLabel("翻译方向")
                    .help("翻译方向：\(model.targetChinese.map { $0 ? "译成中文" : "译成英文" } ?? "自动方向")")
                    .popover(isPresented: $directionOpen) {
                        VStack(alignment: .leading, spacing: 2) {
                            directionChoice("自动方向", value: nil)
                            directionChoice("译成中文", value: true)
                            directionChoice("译成英文", value: false)
                        }.padding(6).frame(width: 150)
                    }
            }
        }
    }
    private var outputActions: some View {
        HStack(spacing: 6) {
            Button { model.copyAll() } label: { Image(systemName: "square.on.square") }
                .buttonStyle(EditorIconButtonStyle()).help("复制整张图像").accessibilityLabel("复制图像")
            EditorShareButton { model.canvas?.finishTextEditing(); return model.doc.flattened() }.frame(width: 32, height: 32)
            Spacer(minLength: 24)
            Button { model.inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(EditorIconButtonStyle())
                .background(model.inspectorVisible ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .help("显示或隐藏检查器").accessibilityLabel("显示或隐藏检查器")
        }
    }
    private var headerSeparator: some View { Rectangle().fill(EditorStyle.separator).frame(width: 1, height: 20).padding(.horizontal, 7) }
    private func directionChoice(_ title: String, value: Bool?) -> some View {
        Button { model.targetChinese = value; directionOpen = false } label: {
            HStack { Text(title); Spacer(); if model.targetChinese == value { Image(systemName: "checkmark").font(.system(size: 10)) } }
                .font(.system(size: 12)).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.targetChinese == value ? .isSelected : [])
    }
    private var markupBar: some View {
        HStack(spacing: 10) {
            toolGroup([.hand, .select]); toolDivider
            ViewThatFits(in: .horizontal) {
                toolGroup([.rect, .ellipse, .line, .arrow, .pen, .highlighter, .text, .number, .mosaic, .blur])
                HStack(spacing: 3) {
                    toolGroup([.rect, .ellipse, .arrow, .pen, .text, .mosaic])
                    Menu {
                        ForEach([Tool.line, .highlighter, .number, .blur], id: \.self) { tool in
                            Button { model.chooseTool(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 26).help("更多标注工具")
                }
            }
            toolDivider; toolButton(.crop); fixButton
            Spacer(minLength: 0)
            Menu {
                Button("适合窗口") { model.canvas?.zoomToFit() }
                Divider()
                ForEach([25, 50, 100, 150, 200, 400, 800], id: \.self) { p in
                    Button("\(p)%") { model.canvas?.setZoomPercent(p) }
                }
            } label: { Text(model.zoomFitted ? "适合窗口" : "\(model.zoomPercent)%").font(.system(size: 11)).monospacedDigit() }
            .menuStyle(.borderlessButton).fixedSize().help("缩放：捏合或 ⌘+ / ⌘-；⌘0 恢复 100%")
        }.padding(.horizontal, 16).frame(height: 46).background(.bar)
    }
    /// Blue while there are loose objects to fix, white once everything is fixed.
    private var fixButton: some View {
        let loose = model.revision >= 0 && model.doc.hasEditableObjects
        return Button { model.fixAll() } label: {
            Text("固定").font(.system(size: 12, weight: .medium))
                .foregroundStyle(loose ? Color.white : Color.primary.opacity(0.45))
                .padding(.horizontal, 12).frame(height: 28)
                .background(loose ? EditorStyle.accent : Color.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(loose ? Color.clear : EditorStyle.separator, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!loose).help("固定全部，可撤销 ⇧⌘F").accessibilityLabel("固定")
    }
    private var toolDivider: some View { Divider().frame(height: 18) }
    private func toolGroup(_ tools: [Tool]) -> some View {
        HStack(spacing: 3) { ForEach(tools, id: \.self) { toolButton($0) } }
    }
    private func toolButton(_ tool: Tool) -> some View {
        Button { model.chooseTool(tool) } label: {
            if tool == .text { Text("A").font(.system(size: 16, weight: .bold, design: .serif)) }
            else { Image(systemName: tool.symbol) }
        }
            .buttonStyle(EditorIconButtonStyle(selected: model.tool == tool))
            .help(tool.title).accessibilityLabel(tool.title)
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "photo").font(.system(size: 10))
            Text("\(Int(model.doc.size.width)) × \(Int(model.doc.size.height)) 像素").monospacedDigit()
            Text("·"); Text(model.currentEntry?.formatLabel ?? "PNG")
            Spacer(minLength: 12)
            if model.hasPatch {
                Text("区块可持续编辑")
                Button("删除区块") { model.canvas?.cancelPatch() }
            } else { Text(model.tool.hint).lineLimit(1).truncationMode(.tail) }
            HStack(spacing: 3) {
                ForEach([50, 100, 150], id: \.self) { value in
                    Button { model.canvas?.setZoomPercent(value) } label: {
                        Text("\(value)%").monospacedDigit().padding(.horizontal, 5).padding(.vertical, 3)
                            .foregroundStyle(model.zoomPercent == value ? EditorStyle.accent : Color.secondary)
                            .background(model.zoomPercent == value ? EditorStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).help("缩放到 \(value)%")
                }
            }.padding(.leading, 8)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
            .controlSize(.mini).padding(.horizontal, 16).frame(height: EditorStyle.footerHeight).background(.bar)
    }

    private var historyPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SideTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue).font(.system(size: 12, weight: tab == item ? .medium : .regular))
                            .foregroundStyle(tab == item ? Color.primary.opacity(0.82) : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .background(tab == item ? EditorStyle.well : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(tab == item ? 0.12 : 0), radius: 1.5, y: 1)
                    }.buttonStyle(.plain).accessibilityLabel(item.rawValue).accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(2).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 14).frame(height: 46).padding(.bottom, 12)
            switch tab {
            case .shots: captureActions; categoryPicker; historyList
            case .browse: BrowseSidebar(model: browse)
            }
            Divider()
            HStack {
                Text(tab == .shots ? "\(model.entries.count) 张截图" : "\(browse.groups.count) 个分组").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { SettingsWindow.show() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("设置 ⌘,").accessibilityLabel("设置")
            }.padding(.horizontal, 16).frame(height: EditorStyle.footerHeight)
        }.frame(width: EditorStyle.sidebarWidth).background(EditorMaterial().overlay(EditorStyle.sidebar.opacity(0.88)))
    }
    private var captureActions: some View {
        Button { model.newBlank() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 16))
                Text("新建画板").font(.system(size: 13, weight: .medium))
            }.frame(maxWidth: .infinity).frame(height: 42).contentShape(Rectangle())
        }.buttonStyle(.plain).help("新建一块空白画板（尺寸见设置）")
            .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(EditorStyle.separator, lineWidth: 0.5)).padding(.horizontal, 14)
    }
    private var categoryPicker: some View {
        Picker("", selection: $category) {
            Text("全部").tag(HistoryGroup?.none)
            Text("编辑").tag(HistoryGroup?.some(.normal))
            Text("翻译").tag(HistoryGroup?.some(.translate))
            Text("文字").tag(HistoryGroup?.some(.ocr))
        }.pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }
    private var filteredEntries: [HistoryEntry] {
        model.entries.filter { category == nil || $0.group == category }
    }
    private var days: [Date] { Array(Set(filteredEntries.map { Calendar.current.startOfDay(for: $0.date) })).sorted(by: >) }
    private func groupTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }
    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if filteredEntries.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 25, weight: .light))
                            Text("这个分类下还没有截图").font(.system(size: 12))
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    ForEach(days, id: \.self) { day in
                        let entries = filteredEntries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                        HStack {
                            Text(groupTitle(day)).fontWeight(.semibold); Spacer(); Text("\(entries.count) 张")
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 11).padding(.top, 15).padding(.bottom, 4)
                        ForEach(entries) { entry in HistoryThumb(model: model, entry: entry).id(entry.id) }
                    }
                }.padding(.horizontal, 9).padding(.bottom, 12)
            }.onChange(of: model.currentID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
    private func editFromBrowse(_ image: CGImage) {
        guard let entry = model.history.add(image, format: settings.imageFormat, namePrefix: "图片") else { return }
        model.entries = model.history.entries; model.open(entry); tab = .shots
    }
}

private struct HistoryThumb: View {
    @ObservedObject var model: EditorModel
    let entry: HistoryEntry
    @State private var hovering = false
    private var selected: Bool { entry.id == model.currentID }
    var body: some View {
        Button { model.open(entry) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(.white)
                    if let thumb = model.history.thumbnail(for: entry.id, maxPixel: 400) {
                        Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                    } else { Image(systemName: "photo").foregroundStyle(.tertiary) }
                }.frame(height: 104).clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? EditorStyle.accent : EditorStyle.separator, lineWidth: selected ? 1.5 : 0.5))
                    .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
                HStack(spacing: 4) {
                    Text(entry.shortName).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(minLength: 0)
                    Text(entry.date, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }.foregroundStyle(selected ? EditorStyle.accent : Color.primary.opacity(0.7))
                if selected { Text("\(entry.width) × \(entry.height) · \(entry.formatLabel)").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(9).contentShape(RoundedRectangle(cornerRadius: 8))
                .background(selected ? EditorStyle.accent.opacity(0.12) : Color.primary.opacity(hovering ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? EditorStyle.accent.opacity(0.12) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel("\(entry.shortName)，\(entry.date.formatted())").accessibilityAddTraits(selected ? .isSelected : [])
            .help(entry.displayName).contextMenu {
                Button("删除", role: .destructive) { model.deleteEntry(entry) }
            }
    }
}
