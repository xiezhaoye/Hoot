import AppKit
import Carbon
import ShotPadCore
import UniformTypeIdentifiers

enum Settings {
    static var historyLimit: Int {
        get { let v = UserDefaults.standard.integer(forKey: "historyLimit"); return v > 0 ? v : 50 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit") }
    }

    static var defaultHistoryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotPad/History", isDirectory: true)
    }

    /// Where screenshots are stored; changing it in the settings takes effect on the next launch.
    static var historyDirectory: URL {
        get { UserDefaults.standard.string(forKey: "historyDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultHistoryDirectory }
        set { UserDefaults.standard.set(newValue.path, forKey: "historyDirectory") }
    }
}

extension CGImage {
    var pngData: Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

enum Clipboard {
    static func write(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = image.pngData { pb.setData(png, forType: .png) }
    }

    /// Pixel-exact image from the pasteboard (PNG first, then TIFF).
    static func readImage() -> CGImage? {
        let pb = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type),
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        }
        return nil
    }
}

/// Global shortcuts via Carbon (no accessibility permission needed).
enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var refs: [UInt32: EventHotKeyRef] = [:]

    static func register(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { HotKey.handlers[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        handlers[id] = handler
        if let old = refs[id] { UnregisterEventHotKey(old); refs[id] = nil }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x53504144), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }
}
