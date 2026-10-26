import AppKit
import SwiftUI
import Security
import CryptoKit
import ShotPadCore

/// Updates come only from the public Hoot release feed. A matching hash is not
/// sufficient: the extracted app must also have the original Apple team signature.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    private var timer: Timer?
    @Published var message = ""
    @Published var busy = false
    @Published var available: Release?
    @Published var automaticallyCheck = UserDefaults.standard.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyCheck, forKey: "automaticallyCheckUpdates"); if automaticallyCheck { start() } else { timer?.invalidate(); timer = nil } }
    }
    struct Asset: Decodable { var name: String; var browser_download_url: URL; var digest: String? }
    struct Release: Decodable {
        var tag_name: String; var body: String?; var draft: Bool; var prerelease: Bool; var assets: [Asset]
        var archive: Asset? { assets.first { $0.name.hasPrefix("Hoot-") && $0.name.hasSuffix("-macos-arm64.zip") } }
    }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2" }
    func start() {
        timer?.invalidate()
        guard automaticallyCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86400 { Task { await check() } }
    }
    func check() async {
        guard !busy else { return }; busy = true; message = "正在检查更新…"
        defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/xiezhaoye/Hoot/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Hoot/\(Self.version)", forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("更新服务暂不可用，请稍后重试") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { throw failure("版本信息无效") }
            if !release.draft, !release.prerelease, version.compare(Self.version, options: .numeric) == .orderedDescending, release.archive != nil {
                available = release; message = "发现新版本 \(version)"
            } else { available = nil; message = "当前已是最新版本（\(Self.version)）" }
        } catch { message = "检查失败：\(error.localizedDescription)" }
    }
    func install() async {
        guard !busy, let release = available, let asset = release.archive else { return }
        let alert = NSAlert(); alert.messageText = "安装 \(release.tag_name) 并重新启动 Hoot？"
        alert.informativeText = "全部画板、未固定的对象及撤销记录会保存为草稿，并在重启后恢复。"
        alert.addButton(withTitle: "安装并重启"); alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; message = "正在下载更新…"
        defer { busy = false }
        var staging: URL?
        do {
            guard asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
                  asset.browser_download_url.path.hasPrefix("/xiezhaoye/Hoot/releases/download/"),
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { throw failure("发布包缺少有效的校验信息") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hoot-update-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); staging = directory
            let (download, response) = try await URLSession.shared.download(from: asset.browser_download_url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("下载安装包失败") }
            let zip = directory.appendingPathComponent("release.zip"); try FileManager.default.moveItem(at: download, to: zip)
            message = "正在校验安装包…"
            let expected = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let app = try await Task.detached { try UpdateArchive.prepare(zip: zip, directory: directory, digest: digest, expectedVersion: expected) }.value
            let target = Bundle.main.bundleURL
            guard target.pathExtension == "app", target.lastPathComponent == "Hoot.app",
                  FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw failure("当前安装位置不可写，请将 Hoot 移到你可写的应用程序目录后重试") }
            guard let delegate = NSApp.delegate as? AppDelegate else { throw failure("无法保存编辑现场") }
            try delegate.checkpointEditors()
            let helper = directory.appendingPathComponent("install.sh")
            // All paths are passed as positional arguments, never interpolated into shell code.
            let script = #"""
            #!/bin/bash
            set -euo pipefail
            parent="$1"; source_app="$2"; target="$3"; staging="$4"
            for ((n=0; n<120; n++)); do
              if ! kill -0 "$parent" 2>/dev/null; then break; fi
              /bin/sleep 1
            done
            if kill -0 "$parent" 2>/dev/null; then exit 1; fi
            /usr/bin/codesign --verify --deep --strict -R 'anchor apple generic and identifier "com.xiezhaoye.shotpad" and certificate leaf[subject.OU] = "KPMNP43ZN8"' "$source_app"
            next="${target}.update-$$"; backup="${target}.previous-$$"
            /usr/bin/ditto "$source_app" "$next"
            /usr/bin/codesign --verify --deep --strict -R 'anchor apple generic and identifier "com.xiezhaoye.shotpad" and certificate leaf[subject.OU] = "KPMNP43ZN8"' "$next"
            /bin/mv "$target" "$backup"
            if ! /bin/mv "$next" "$target"; then /bin/mv "$backup" "$target"; exit 1; fi
            if ! /usr/bin/open "$target"; then
              /bin/mv "$target" "$next"; /bin/mv "$backup" "$target"; /usr/bin/open "$target"; exit 1
            fi
            # Keep the previous signed app as a recovery copy; a later update can remove it.
            /bin/rm -rf "$staging"
            """#
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), app.path, target.path, directory.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); staging = nil; message = "重启后恢复编辑现场…"; NSApp.terminate(nil)
        } catch {
            message = "更新失败：\(error.localizedDescription)"
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
    }

}
private func failure(_ message: String) -> NSError { NSError(domain: "Hoot.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
