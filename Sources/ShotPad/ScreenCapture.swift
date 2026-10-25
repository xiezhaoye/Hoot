import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

struct WindowInfo {
    let rect: CGRect   // global coordinates, top-left origin (same space as CGWindowList)
}

enum ScreenCapture {
    static func captureAll() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == number }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
            cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        return shots
    }

    /// On-screen application windows, front to back, excluding our own.
    static func windows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width >= 40, rect.height >= 30 else { return nil }
            return WindowInfo(rect: rect)
        }
    }
}
