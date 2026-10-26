import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}
struct WindowInfo {
    let rect: CGRect
    var ownerPID: Int32 = 0
    var windowID: CGWindowID = 0
}

@MainActor
enum ScreenCapture {
    private static var cachedContent: SCShareableContent?
    private static var loading: Task<SCShareableContent, Error>?
    private static var displayIDs: [CGDirectDisplayID] = []
    static func warmUp() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task { _ = try? await content() }
    }
    private static func content() async throws -> SCShareableContent {
        let ids = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        if ids != displayIDs { cachedContent = nil; loading?.cancel(); loading = nil; displayIDs = ids }
        if let cachedContent { return cachedContent }
        if let loading { return try await loading.value }
        let task = Task { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        loading = task
        do {
            let result = try await task.value
            if ids == displayIDs { cachedContent = result; loading = nil }
            return result
        } catch { if ids == displayIDs { loading = nil }; throw error }
    }
    static func captureAll() async throws -> [ScreenShot] {
        do { return try await capture(using: try await content()) }
        catch { cachedContent = nil; return try await capture(using: try await content()) }
    }
    private static func capture(using content: SCShareableContent) async throws -> [ScreenShot] {
        let jobs = NSScreen.screens.compactMap { screen -> (NSScreen, SCDisplay, SCStreamConfiguration)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == number }) else { return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
            cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
            cfg.showsCursor = false
            return (screen, display, cfg)
        }
        guard !jobs.isEmpty, jobs.count == NSScreen.screens.count else {
            throw NSError(domain: "Hoot.Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "显示器列表已变化，请重新截图"])
        }
        return try await withThrowingTaskGroup(of: (Int, ScreenShot).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: job.1, excludingWindows: []), configuration: job.2)
                    return (index, ScreenShot(screen: job.0, image: image))
                }
            }
            var result: [(Int, ScreenShot)] = []
            for try await shot in group { result.append(shot) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
    /// Front to back, including Hoot, utility panels, dialogs and popovers.
    static func windows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < Int(CGShieldingWindowLevel()),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.width >= 10, rect.height >= 10 else { return nil }
            return WindowInfo(rect: rect, ownerPID: w[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                              windowID: w[kCGWindowNumber as String] as? CGWindowID ?? 0)
        }
    }
}
