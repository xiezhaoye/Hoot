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
    @Published var historySide: HistorySide { didSet { d.set(historySide.rawValue, forKey: "historySide") } }
    @Published var annotationColor: Color { didSet { store(annotationColor, "annotationColor") } }
    @Published var selectionColor: Color { didSet { store(selectionColor, "selectionColor") } }
    @Published var baseURL: String { didSet { d.set(baseURL, forKey: "llmBaseURL") } }
    @Published var model: String { didSet { d.set(model, forKey: "llmModel") } }
    @Published var apiKey: String { didSet { Keychain.set("apiKey", apiKey) } }

    private init() {
        alwaysInDock = d.object(forKey: "alwaysInDock") as? Bool ?? true
        historySide = HistorySide(rawValue: d.string(forKey: "historySide") ?? "") ?? .right
        annotationColor = Self.load(d, "annotationColor") ?? Color(red: 0.95, green: 0.2, blue: 0.2)
        selectionColor = Self.load(d, "selectionColor") ?? Color(red: 0.0, green: 0.48, blue: 1.0)
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
