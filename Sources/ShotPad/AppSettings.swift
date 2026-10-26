import AppKit
import Security
import SwiftUI
import ShotPadCore

enum Keychain {
    private static let service = "ShotPad.LLM"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// User preferences shared by the editor, the capture overlay and the settings window.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    enum HistorySide: String { case left, right }

    @Published var alwaysInDock: Bool { didSet { d.set(alwaysInDock, forKey: "alwaysInDock"); (NSApp.delegate as? AppDelegate)?.refreshPolicy() } }
    @Published var smartCapture: Bool { didSet { d.set(smartCapture, forKey: "smartCapture") } }
    @Published var roundedCapture: Bool { didSet { d.set(roundedCapture, forKey: "roundedCapture") } }
    @Published var captureRadius: Double { didSet { d.set(captureRadius, forKey: "captureRadius") } }
    @Published var copyAfterCapture: Bool { didSet { d.set(copyAfterCapture, forKey: "copyAfterCapture") } }
    @Published var boardWidth: Int { didSet { d.set(boardWidth, forKey: "boardWidth") } }
    @Published var boardHeight: Int { didSet { d.set(boardHeight, forKey: "boardHeight") } }
    var boardSize: CGSize { CGSize(width: max(boardWidth, 200), height: max(boardHeight, 200)) }
    /// Capture shortcut: virtual key code, Carbon modifier mask (⌘256 ⇧512 ⌥2048 ⌃4096) and its display label.
    @Published var captureKeyCode: Int { didSet { d.set(captureKeyCode, forKey: "captureKeyCode"); shortcutChanged() } }
    @Published var captureModifiers: Int { didSet { d.set(captureModifiers, forKey: "captureModifiers"); shortcutChanged() } }
    @Published var captureKeyLabel: String { didSet { d.set(captureKeyLabel, forKey: "captureKeyLabel") } }
    var captureShortcutText: String {
        (captureModifiers & 4096 != 0 ? "⌃" : "") + (captureModifiers & 2048 != 0 ? "⌥" : "")
            + (captureModifiers & 512 != 0 ? "⇧" : "") + (captureModifiers & 256 != 0 ? "⌘" : "") + captureKeyLabel
    }
    private func shortcutChanged() { (NSApp.delegate as? AppDelegate)?.registerCaptureHotKey() }
    @Published var imageFormat: ImageFormat { didSet { d.set(imageFormat.rawValue, forKey: "imageFormat") } }
    @Published var historySide: HistorySide { didSet { d.set(historySide.rawValue, forKey: "historySide") } }
    @Published var annotationColor: Color { didSet { store(annotationColor, "annotationColor") } }
    @Published var selectionColor: Color { didSet { store(selectionColor, "selectionColor") } }
    @Published var baseURL: String { didSet { d.set(baseURL, forKey: "llmBaseURL") } }
    @Published var model: String { didSet { d.set(model, forKey: "llmModel") } }
    @Published var apiKey: String { didSet { Keychain.set("apiKey", apiKey) } }

    /// Most recently used annotation colours, newest first (at most 10).
    @Published private(set) var recentColors: [RGBA] = []

    func noteUsed(_ c: RGBA) {
        var list = recentColors.filter { abs($0.r - c.r) + abs($0.g - c.g) + abs($0.b - c.b) + abs($0.a - c.a) > 0.01 }
        list.insert(c, at: 0)
        recentColors = Array(list.prefix(10))
        d.set(recentColors.map { [$0.r, $0.g, $0.b, $0.a] }, forKey: "recentColors")
    }

    private init() {
        alwaysInDock = d.object(forKey: "alwaysInDock") as? Bool ?? true
        smartCapture = d.object(forKey: "smartCapture") as? Bool ?? true
        roundedCapture = d.bool(forKey: "roundedCapture")
        captureRadius = d.object(forKey: "captureRadius") as? Double ?? 12
        copyAfterCapture = d.bool(forKey: "copyAfterCapture")
        imageFormat = d.string(forKey: "imageFormat").flatMap(ImageFormat.init(rawValue:)) ?? .png
        captureKeyCode = d.object(forKey: "captureKeyCode") as? Int ?? 0
        captureModifiers = d.object(forKey: "captureModifiers") as? Int ?? (4096 | 2048)
        captureKeyLabel = d.string(forKey: "captureKeyLabel") ?? "A"
        boardWidth = d.object(forKey: "boardWidth") as? Int ?? 1920
        boardHeight = d.object(forKey: "boardHeight") as? Int ?? 1080
        historySide = HistorySide(rawValue: d.string(forKey: "historySide") ?? "") ?? .right
        annotationColor = Self.load(d, "annotationColor") ?? Color(red: 0.95, green: 0.2, blue: 0.2)
        selectionColor = Self.load(d, "selectionColor") ?? Color(red: 0.0, green: 0.48, blue: 1.0)
        recentColors = ((d.array(forKey: "recentColors") as? [[Double]]) ?? []).filter { $0.count == 4 }.map { RGBA($0[0], $0[1], $0[2], $0[3]) }
        baseURL = d.string(forKey: "llmBaseURL") ?? ""
        model = d.string(forKey: "llmModel") ?? ""
        apiKey = Keychain.get("apiKey")
    }

    var llm: LLMConfig? {
        let c = LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
        return c.isUsable ? c : nil
    }

    var selectionNSColor: NSColor { RGBAWrapper(selectionColor).nsColor }

    private func store(_ c: Color, _ key: String) {
        let r = RGBAWrapper(c).rgba
        d.set([r.r, r.g, r.b, r.a], forKey: key)
    }

    private static func load(_ d: UserDefaults, _ key: String) -> Color? {
        guard let v = d.array(forKey: key) as? [Double], v.count == 4 else { return nil }
        return Color(.sRGB, red: v[0], green: v[1], blue: v[2], opacity: v[3])
    }
}
