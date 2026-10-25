import Foundation

/// Connection settings for an OpenAI-compatible chat completions endpoint.
public struct LLMConfig: Equatable {
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }

    public var isUsable: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public enum LLMTranslator {
    public enum Failure: LocalizedError {
        case badURL, http(Int, String), shape(String)
        public var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let code, let body): return "接口返回 \(code)：\(body.prefix(120))"
            case .shape(let why): return "返回内容无法解析：\(why)"
            }
        }
    }

    /// Accepts `https://host/v1`, `https://host/v1/` or a full `.../chat/completions` URL.
    public static func endpoint(_ base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.hasSuffix("/chat/completions") { s += "/chat/completions" }
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    public static func makeRequest(lines: [String], toChinese: Bool, config: LLMConfig) -> URLRequest? {
        guard let url = endpoint(config.baseURL),
              let payload = try? JSONSerialization.data(withJSONObject: lines),
              let payloadText = String(data: payload, encoding: .utf8) else { return nil }
        let target = toChinese ? "Simplified Chinese" : "English"
        let system = "You are a translation engine. The user sends a JSON array of strings. Translate every string into \(target). "
            + "Reply with ONLY a JSON array of strings, same length and order, no commentary, no code fences."
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "messages": [["role": "system", "content": system], ["role": "user", "content": payloadText]],
        ]
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func parse(_ data: Data, expected: Int) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.shape("缺少 choices[0].message.content") }
        guard let open = content.firstIndex(of: "["), let close = content.lastIndex(of: "]"), open < close,
              let arrayData = String(content[open...close]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: arrayData) as? [Any] else { throw Failure.shape("不是 JSON 数组") }
        let strings = array.map { ($0 as? String) ?? "\($0)" }
        guard strings.count == expected else { throw Failure.shape("条数不一致（\(strings.count)/\(expected)）") }
        return strings
    }

    public static func translate(lines: [String], toChinese: Bool, config: LLMConfig) async throws -> [String] {
        guard let request = makeRequest(lines: lines, toChinese: toChinese, config: config) else { throw Failure.badURL }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try parse(data, expected: lines.count)
    }
}
