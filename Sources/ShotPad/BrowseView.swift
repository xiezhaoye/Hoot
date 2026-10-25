import AppKit
import ImageIO
import SwiftUI
import ShotPadCore

/// State of the 浏览 tab: groups of folders on the left, the selected folder's images on the right.
@MainActor
final class BrowseModel: ObservableObject {
    @Published var groups: [BrowseGroup] = []
    @Published var selectedFolder: BrowseFolder?
    @Published var files: [URL] = []
    @Published var index = 0
    @Published var gridMode = false
    @Published var renamingGroup: UUID?

    private let store: BrowseStore
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ShotPad", isDirectory: true)
        store = BrowseStore(file: dir.appendingPathComponent("browse.json"))
        groups = store.groups
    }

    var current: URL? { files.indices.contains(index) ? files[index] : nil }

    func select(_ folder: BrowseFolder) {
        selectedFolder = folder
        gridMode = false
        index = 0
        reloadFiles()
        watch(folder)
    }

    func reloadFiles() {
        guard let f = selectedFolder else { files = []; return }
        let keep = current
        files = f.exists ? BrowseStore.images(in: f.url) : []
        index = keep.flatMap { files.firstIndex(of: $0) } ?? min(index, max(files.count - 1, 0))
    }

    /// Re-lists the folder when files are added or removed in Finder.
    private func watch(_ folder: BrowseFolder) {
        watcher?.cancel()
        watcher = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadFiles() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func page(_ delta: Int) {
        guard !files.isEmpty else { return }
        index = min(max(index + delta, 0), files.count - 1)
    }

    // MARK: Groups

    func addGroup() {
        let g = store.addGroup("新分组")
        groups = store.groups
        renamingGroup = g.id
    }

    func rename(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { store.renameGroup(id, to: t); groups = store.groups }
        renamingGroup = nil
    }

    func removeGroup(_ id: UUID) {
        if let sel = selectedFolder, groups.first(where: { $0.id == id })?.folders.contains(sel) == true { clearSelection() }
        store.removeGroup(id)
        groups = store.groups
    }

    func addFolders(_ urls: [URL], to groupID: UUID) {
        var last: BrowseFolder?
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue else { continue }
            if let f = store.addFolder(u, to: groupID) { last = f }
        }
        groups = store.groups
        if let last { select(last) }
    }

    func chooseFolders(for groupID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK { addFolders(panel.urls, to: groupID) }
    }

    func removeFolder(_ folder: BrowseFolder, from groupID: UUID) {
        if selectedFolder == folder { clearSelection() }
        store.removeFolder(folder.id, from: groupID)
        groups = store.groups
    }

    private func clearSelection() {
        selectedFolder = nil
        files = []
        index = 0
        watcher?.cancel()
        watcher = nil
    }
}

// MARK: - Image loading

enum ImageLoader {
    private static let cache: NSCache<NSString, CGImage> = { let c = NSCache<NSString, CGImage>(); c.countLimit = 400; return c }()

    /// Downsampled copy with EXIF orientation applied.
    static func load(_ url: URL, maxPixel: Int) async -> CGImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    /// Full resolution, orientation applied — used when sending a picture to the editor.
    static func loadFull(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let w = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ] as CFDictionary)
    }
}

// MARK: - Sidebar

struct BrowseSidebar: View {
    @ObservedObject var model: BrowseModel
    @State private var expanded: Set<UUID> = []
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.groups) { group in groupRow(group) }
                    if model.groups.isEmpty {
                        Text("点下方“新建分组”，再往分组里添加文件夹").font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            Divider()
            Button { model.addGroup() } label: { Label("新建分组", systemImage: "plus") }
                .buttonStyle(.borderless).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 42)
        }
        .onChange(of: model.groups.count) { _, _ in expanded.formUnion(model.groups.map(\.id)) }
        .onAppear { expanded.formUnion(model.groups.map(\.id)) }
    }

    @ViewBuilder private func groupRow(_ group: BrowseGroup) -> some View {
        let open = expanded.contains(group.id)
        HStack(spacing: 9) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
            Image(systemName: "square.stack").font(.system(size: 15))
            if model.renamingGroup == group.id {
                TextField("分组名", text: $draft).textFieldStyle(.roundedBorder)
                    .onSubmit { model.rename(group.id, to: draft) }
                    .onAppear { draft = group.name }
            } else {
                Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.chooseFolders(for: group.id) } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless).frame(width: 28, height: 30).help("添加文件夹")
        }
        .frame(minHeight: 38).padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture { if open { expanded.remove(group.id) } else { expanded.insert(group.id) } }
        .dropDestination(for: URL.self) { urls, _ in model.addFolders(urls, to: group.id); expanded.insert(group.id); return true }
        .contextMenu {
            Button("添加文件夹…") { model.chooseFolders(for: group.id) }
            Button("重命名") { draft = group.name; model.renamingGroup = group.id }
            Divider()
            Button("删除分组", role: .destructive) { model.removeGroup(group.id) }
        }
        if open {
            ForEach(group.folders) { folder in
                let missing = !folder.exists
                HStack(spacing: 9) {
                    Image(systemName: missing ? "exclamationmark.triangle" : "folder").font(.system(size: 17)).frame(width: 21)
                    Text(folder.name).font(.system(size: 14)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(missing ? .secondary : .primary)
                .frame(minHeight: 42).padding(.horizontal, 8).padding(.leading, 17)
                .background(RoundedRectangle(cornerRadius: 5).fill(model.selectedFolder == folder ? Color.accentColor.opacity(0.25) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.select(folder) }
                .help(missing ? "文件夹不存在或已被移动：\(folder.path)" : folder.path)
                .contextMenu {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                        .disabled(missing)
                    Button("从分组移除", role: .destructive) { model.removeFolder(folder, from: group.id) }
                }
            }
        }
    }
}

// MARK: - Preview

/// Receives key events for paging; kept as the first responder while the browse tab is on screen.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    final class V: NSView {
        var onKey: (NSEvent) -> Bool = { _ in false }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { if !onKey(event) { super.keyDown(with: event) } }
        override func viewDidMoveToWindow() { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) } }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with: event) }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.onKey = onKey; return v }
    func updateNSView(_ v: V, context: Context) {
        v.onKey = onKey
        if v.window?.firstResponder !== v, !(v.window?.firstResponder is NSText) {
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
    }
}

struct BrowseDetail: View {
    @ObservedObject var model: BrowseModel
    let onEdit: (CGImage) -> Void
    @State private var image: CGImage?
    @State private var columns = 4

    private let cell: CGFloat = 140

    var body: some View {
        ZStack {
            KeyCatcher(onKey: handleKey).frame(width: 1, height: 1)
            Color.white.allowsHitTesting(false)
            if model.selectedFolder == nil {
                placeholder("从左侧选一个文件夹开始浏览")
            } else if model.files.isEmpty {
                placeholder(model.selectedFolder?.exists == false ? "这个文件夹不存在或已被移动" : "这个文件夹里没有图片")
            } else if model.gridMode {
                grid
            } else {
                single
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).allowsHitTesting(false)
    }

    // MARK: Single image

    private var single: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(12)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                HStack(spacing: 0) {
                    pagingArea(-1, symbol: "chevron.left")
                    pagingArea(1, symbol: "chevron.right")
                }
            }
            }
            Divider()
            HStack {
                Text(model.current?.lastPathComponent ?? "").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.index + 1) / \(model.files.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .controlSize(.small).padding(.horizontal, 10).frame(height: EditorStyle.footerHeight)
            .background(.bar)
        }
        .task(id: model.current) {
            guard let url = model.current else { image = nil; return }
            image = nil
            let loaded = await ImageLoader.load(url, maxPixel: 3200)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    /// Each half of the preview is a paging target; double-click still opens the editor.
    private func pagingArea(_ delta: Int, symbol: String) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: delta < 0 ? .leading : .trailing) {
                Image(systemName: symbol).font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 42, height: 54)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 18)
                    .opacity((delta < 0 ? model.index > 0 : model.index < model.files.count - 1) ? 1 : 0.25)
                    .allowsHitTesting(false)
            }
            .onTapGesture(count: 2) { edit() }
            .onTapGesture { model.page(delta) }
            .accessibilityElement().accessibilityLabel(delta < 0 ? "上一张" : "下一张")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.page(delta) }
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 8)], spacing: 8) {
                        ForEach(Array(model.files.enumerated()), id: \.offset) { i, url in
                            ThumbCell(url: url, selected: i == model.index, size: cell)
                                .id(i)
                                .onTapGesture(count: 2) { model.index = i; model.gridMode = false }
                                .onTapGesture { model.index = i }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.index) { _, i in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i) } }
                .onAppear { proxy.scrollTo(model.index, anchor: .center) }
            }
            .onAppear { columns = columnCount(geo.size.width) }
            .onChange(of: geo.size.width) { _, w in columns = columnCount(w) }
        }
    }

    private func columnCount(_ width: CGFloat) -> Int { max(1, Int((width - 24 + 8) / (cell + 8))) }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        guard model.selectedFolder != nil, !model.files.isEmpty else { return false }
        if !e.modifierFlags.intersection([.command, .option, .control]).isEmpty { return false }
        switch e.keyCode {
        case 123: model.page(-1)                       // ←
        case 124: model.page(1)                        // →
        case 126:                                      // ↑
            if model.gridMode { model.page(-columns) } else { model.gridMode = true }
        case 125:                                      // ↓
            if model.gridMode {
                if model.index + columns < model.files.count { model.page(columns) } else { model.gridMode = false }
            }
        case 36, 76:                                   // return
            if model.gridMode { model.gridMode = false } else { edit() }
        case 53:                                       // esc
            if model.gridMode { model.gridMode = false } else { return false }
        case 49:                                       // space: same as grid <-> single toggle
            model.gridMode.toggle()
        default: return false
        }
        return true
    }

    private func edit() {
        guard let url = model.current else { return }
        guard let full = ImageLoader.loadFull(url) else { NSSound.beep(); return }
        onEdit(full)
    }
}

private struct ThumbCell: View {
    let url: URL
    let selected: Bool
    let size: CGFloat
    @State private var thumb: CGImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFit() }
            }
            .frame(width: size, height: size * 0.75)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: size)
        }
        .task { thumb = await ImageLoader.load(url, maxPixel: 280) }
    }
}
