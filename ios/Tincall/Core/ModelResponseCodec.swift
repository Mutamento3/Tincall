import Foundation

/// The non-streaming and streaming decoders share the same terminal-status rules.
enum ModelResponseCodec {
    nonisolated static func responseText(_ data: Data, provider: ConnectionProvider) throws -> String {
        let object = try ModelProtocolJSON.object(data)
        guard object["error"] == nil else { throw TincallError(message: String(localized: "模型服务返回错误")) }
        let text: String
        let reason: String?
        switch provider {
        case .openAICompatible:
            let choice = (object["choices"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 }) ?? [:]
            let message = choice["message"] as? [String: Any] ?? [:]
            guard !(message["tool_calls"] is [Any]), !(message["function_call"] is [String: Any]) else { throw TincallError(message: ModelProtocolJSON.toolError) }
            text = message["content"] as? String ?? ""; reason = choice["finish_reason"] as? String
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]] ?? []
            guard !blocks.contains(where: { ($0["type"] as? String)?.contains("tool_use") == true }) else { throw TincallError(message: ModelProtocolJSON.toolError) }
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(); reason = object["stop_reason"] as? String
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 }) ?? [:]
            text = try ModelProtocolJSON.geminiText(candidate); reason = candidate["finishReason"] as? String
        default: throw TincallError(message: String(localized: "请选择模型协议"))
        }
        guard let reason else { throw TincallError(message: String(localized: "模型响应缺少完成状态")) }
        if let error = ModelProtocolJSON.finishError(reason, provider: provider) { throw TincallError(message: error) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TincallError(message: String(localized: "模型未返回可显示的回复文字")) }
        return text
    }

    nonisolated static func responseReasoning(_ data: Data, provider: ConnectionProvider) throws -> String {
        let object = try ModelProtocolJSON.object(data)
        switch provider {
        case .openAICompatible:
            let choice = (object["choices"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 })
            let message = choice?["message"] as? [String: Any] ?? [:]
            return message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? ""
        case .anthropic:
            return (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "thinking" }
                .compactMap { $0["thinking"] as? String }.joined()
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 }) ?? [:]
            return ModelProtocolJSON.geminiReasoning(candidate)
        default: return ""
        }
    }

    nonisolated static func modelListPage(_ data: Data, provider: ConnectionProvider) throws -> (models: [String], nextCursor: String?) {
        let object = try ModelProtocolJSON.object(data)
        guard object["error"] == nil else { throw TincallError(message: String(localized: "拉取模型失败")) }
        if provider == .gemini {
            guard let rows = object["models"] as? [[String: Any]] else { throw TincallError(message: String(localized: "连接未返回 Gemini 模型列表")) }
            let names = rows.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }.compactMap { $0["name"] as? String }
            return (names.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }, object["nextPageToken"] as? String)
        }
        guard provider == .openAICompatible || provider == .anthropic, let rows = object["data"] as? [[String: Any]] else { throw TincallError(message: String(localized: "连接未返回模型列表")) }
        var cursor: String?
        if object["has_more"] as? Bool == true {
            guard let last = object["last_id"] as? String, !last.isEmpty else { throw TincallError(message: String(localized: "模型列表缺少分页游标")) }
            cursor = last
        }
        return (rows.compactMap { $0["id"] as? String }, cursor)
    }
}

/// Text-only SSE decoding for the three native protocols. Reasoning is never spoken.
struct ChatCompletionStreamDecoder {
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var errorResponseText: String?
    private(set) var finishReason: String?
    private(set) var isDone = false
    private let provider: ConnectionProvider
    private var eventLines: [String] = []
    private var eventBytes = 0
    private var terminalError: String?

    init(provider: ConnectionProvider = .openAICompatible) { self.provider = provider }

    mutating func consume(line: String) throws -> String? {
        guard !isDone else { return nil }
        if line.isEmpty { return try flushEvent() }
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            let data = value.first == " " ? String(value.dropFirst()) : String(value)
            eventBytes += data.utf8.count
            guard eventBytes <= 1_048_576 else { throw TincallError(message: String(localized: "模型流式事件过大")) }
            eventLines.append(data)
        }
        return nil
    }

    mutating func finish() throws -> String? {
        let delta = try flushEvent()
        if let terminalError { throw TincallError(message: terminalError) }
        guard isDone, finishReason != nil else { throw TincallError(message: String(localized: "模型流式连接提前结束，回复未完成")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TincallError(message: String(localized: "模型未返回可显示的回复文字"))
        }
        return delta
    }

    private mutating func flushEvent() throws -> String? {
        guard !eventLines.isEmpty else { return nil }
        let payload = eventLines.joined(separator: "\n")
        eventLines.removeAll(keepingCapacity: true)
        eventBytes = 0
        if payload == "[DONE]", provider == .openAICompatible { isDone = true; return nil }
        let object = try ModelProtocolJSON.object(Data(payload.utf8))
        if object["error"] != nil || object["type"] as? String == "error" {
            errorResponseText = payload
            throw TincallError(message: String(localized: "模型服务在生成时返回错误"))
        }
        var delta = ""
        switch provider {
        case .openAICompatible:
            guard let choice = (object["choices"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return nil }
            let content = choice["delta"] as? [String: Any] ?? [:]
            reasoning += content["reasoning_content"] as? String ?? content["reasoning"] as? String ?? ""
            if content["tool_calls"] is [Any] || content["function_call"] is [String: Any] { terminalError = ModelProtocolJSON.toolError }
            delta = content["content"] as? String ?? ""
            if let reason = choice["finish_reason"] as? String { finishReason = reason; terminalError = terminalError ?? ModelProtocolJSON.finishError(reason, provider: provider) }
        case .anthropic:
            switch object["type"] as? String {
            case "content_block_start":
                let block = object["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "text" { delta = block["text"] as? String ?? "" }
                else if block["type"] as? String == "thinking" { reasoning += block["thinking"] as? String ?? "" }
                else if (block["type"] as? String)?.contains("tool_use") == true { terminalError = ModelProtocolJSON.toolError }
            case "content_block_delta":
                let block = object["delta"] as? [String: Any] ?? [:]
                if block["type"] as? String == "text_delta" { delta = block["text"] as? String ?? "" }
                else if block["type"] as? String == "thinking_delta" { reasoning += block["thinking"] as? String ?? "" }
                else if block["type"] as? String == "input_json_delta" { terminalError = ModelProtocolJSON.toolError }
            case "message_delta":
                if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String {
                    finishReason = reason; terminalError = terminalError ?? ModelProtocolJSON.finishError(reason, provider: provider)
                }
            case "message_stop": isDone = true
            default: break
            }
        case .gemini:
            if (object["promptFeedback"] as? [String: Any])?["blockReason"] as? String != nil { terminalError = String(localized: "模型阻止了本次输入，未生成回复") }
            if let candidate = (object["candidates"] as? [[String: Any]])?.first(where: { ($0["index"] as? Int ?? 0) == 0 }) {
                reasoning += ModelProtocolJSON.geminiReasoning(candidate)
                delta = try ModelProtocolJSON.geminiText(candidate)
                if let reason = candidate["finishReason"] as? String {
                    finishReason = reason; terminalError = terminalError ?? ModelProtocolJSON.finishError(reason, provider: provider); isDone = true
                }
            }
        default: throw TincallError(message: String(localized: "请选择模型协议"))
        }
        if terminalError != nil { isDone = true }
        text += delta
        guard text.utf8.count + reasoning.utf8.count <= 8_388_608 else { throw TincallError(message: String(localized: "模型回复超过文字大小上限")) }
        return delta.isEmpty ? nil : delta
    }
}

private enum ModelProtocolJSON {
    static let toolError = String(localized: "此连接返回工具调用，当前直连文本协议不支持执行工具")

    static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TincallError(message: String(localized: "模型响应不是 JSON 对象")) }
            return object
        } catch { throw TincallError(message: String(localized: "模型返回了无法解析的 JSON 内容")) }
    }

    static func finishError(_ reason: String, provider: ConnectionProvider) -> String? {
        switch provider {
        case .openAICompatible: if reason == "stop" { return nil }
        case .anthropic: if reason == "end_turn" || reason == "stop_sequence" { return nil }
        case .gemini: if reason == "STOP" { return nil }
        default: break
        }
        if ["length", "max_tokens", "MAX_TOKENS"].contains(reason) { return String(localized: "模型回复达到长度上限，内容未完整生成") }
        if ["tool_calls", "function_call", "tool_use"].contains(reason) { return toolError }
        return String(localized: "模型以不支持或受限的状态结束，回复未完成")
    }

    static func geminiText(_ candidate: [String: Any]) throws -> String {
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        guard !parts.contains(where: { $0["functionCall"] != nil }) else { throw TincallError(message: toolError) }
        return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    }

    static func geminiReasoning(_ candidate: [String: Any]) -> String {
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.filter { $0["thought"] as? Bool == true }.compactMap { $0["text"] as? String }.joined()
    }
}
