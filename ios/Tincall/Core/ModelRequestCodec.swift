// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Shared by actual requests and previews; contains no credentials or network state.
enum ModelRequestCodec {
    nonisolated static func connectionTestOutputLimit(_ connection: ConnectionProfile) -> Int? {
        // A 64-token test cannot exercise a real thinking preset or its manual budget.
        let thinking = connection.openAIReasoningEffort.map { $0 != .none } == true ||
            connection.anthropicThinkingMode == .adaptive || connection.anthropicThinkingMode == .manual ||
            connection.geminiThinkingLevel != nil || connection.geminiThinkingBudget.map { $0 != 0 } == true
        return thinking ? nil : 64
    }

    /// A bare host receives /v1 (OpenAI/Anthropic) or /v1beta (Gemini); a nonempty base path is retained as the API prefix.
    nonisolated static func resolvedEndpoint(connection: ConnectionProfile, stream: Bool = true) throws -> URL {
        let root = try apiRoot(connection)
        let model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw TincallError(message: String(localized: "请填写模型名称")) }
        switch connection.provider {
        case .openAICompatible: return root.appendingPathComponent("chat/completions")
        case .anthropic: return root.appendingPathComponent("messages")
        case .gemini:
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").inverted) == nil else {
                throw TincallError(message: String(localized: "Gemini 模型名称包含不支持的路径字符"))
            }
            let url = root.appendingPathComponent("models").appendingPathComponent(name + (stream ? ":streamGenerateContent" : ":generateContent"))
            guard stream else { return url }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            return components.url!
        default: throw TincallError(message: String(localized: "请选择模型协议"))
        }
    }

    nonisolated static func modelsEndpoint(connection: ConnectionProfile) throws -> URL { try apiRoot(connection).appendingPathComponent("models") }

    private nonisolated static func apiRoot(_ connection: ConnectionProfile) throws -> URL {
        guard connection.provider.isLanguageModel, let endpoint = connection.endpoint, endpoint.scheme?.lowercased() == "https",
              endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw TincallError(message: String(localized: "请填写 HTTPS 模型基础地址或完整端点，不包含凭据、查询参数或片段"))
        }
        var root = endpoint
        var isCompleteEndpoint = false
        switch connection.provider {
        case .openAICompatible:
            if root.lastPathComponent == "completions", root.deletingLastPathComponent().lastPathComponent == "chat" {
                root.deleteLastPathComponent(); root.deleteLastPathComponent(); isCompleteEndpoint = true
            }
        case .anthropic:
            if root.lastPathComponent == "messages" { root.deleteLastPathComponent(); isCompleteEndpoint = true }
        case .gemini:
            if root.lastPathComponent.hasSuffix(":streamGenerateContent") || root.lastPathComponent.hasSuffix(":generateContent") {
                root.deleteLastPathComponent()
                guard root.lastPathComponent == "models" else { throw TincallError(message: String(localized: "Gemini 完整端点应位于 models 路径下")) }
                root.deleteLastPathComponent()
                isCompleteEndpoint = true
            } else if root.lastPathComponent == "models" { root.deleteLastPathComponent(); isCompleteEndpoint = true }
        default: break
        }
        let path = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty, !isCompleteEndpoint { root.appendPathComponent(connection.provider == .gemini ? "v1beta" : "v1") }
        return root
    }

    nonisolated static func validateParameters(_ connection: ConnectionProfile, maxOutputTokens: Int? = nil) throws {
        if connection.provider == .anthropic, connection.temperature != nil, connection.topP != nil {
            throw TincallError(message: String(localized: "Anthropic 的温度和 Top P 请只启用一项；具体可用值仍取决于模型"))
        }
        if let value = connection.temperature {
            let upper = connection.provider == .anthropic ? 1.0 : 2.0
            guard value.isFinite, (0...upper).contains(value) else { throw TincallError(message: String(localized: "温度应在 0 至 \(Int(upper)) 之间")) }
        }
        if let value = connection.topP { guard value.isFinite, (0...1).contains(value) else { throw TincallError(message: String(localized: "Top P 应在 0 至 1 之间")) } }
        if let value = maxOutputTokens ?? connection.maxOutputTokens { guard value > 0 else { throw TincallError(message: String(localized: "最大输出 Token 数必须大于 0")) } }
        try validateThinking(connection, maxOutputTokens: maxOutputTokens ?? connection.maxOutputTokens)
    }

    private nonisolated static func validateThinking(_ connection: ConnectionProfile, maxOutputTokens: Int?) throws {
        let hasAnthropic = connection.anthropicThinkingMode != nil || connection.anthropicThinkingBudget != nil || connection.anthropicEffort != nil
        let hasGemini = connection.geminiThinkingLevel != nil || connection.geminiThinkingBudget != nil
        guard (connection.openAIReasoningEffort == nil || connection.provider == .openAICompatible),
              (!hasAnthropic || connection.provider == .anthropic), (!hasGemini || connection.provider == .gemini) else {
            throw TincallError(message: String(localized: "思考设置与当前协议不匹配，请清除原协议的思考设置"))
        }
        let model = connection.model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let effort = connection.openAIReasoningEffort {
            if model.hasPrefix("gpt-6-astra"), effort == .none {
                throw TincallError(message: String(localized: "GPT-6 Astra 不支持关闭思考，请选择受支持的思考强度"))
            }
            if model.hasPrefix("gpt-6.1-sol"), effort == .none || effort == .minimal {
                throw TincallError(message: String(localized: "GPT-6.1 Sol 不支持 none／minimal 思考强度"))
            }
        }
        if hasAnthropic {
            guard let mode = connection.anthropicThinkingMode else { throw TincallError(message: String(localized: "请先选择 Anthropic 思考模式")) }
            switch mode {
            case .off:
                guard connection.anthropicThinkingBudget == nil, connection.anthropicEffort == nil else {
                    throw TincallError(message: String(localized: "关闭 Anthropic 思考时不能同时设置预算或强度"))
                }
            case .adaptive:
                guard connection.anthropicThinkingBudget == nil else { throw TincallError(message: String(localized: "Anthropic 自适应思考使用强度，不能同时设置手动预算")) }
            case .manual:
                guard connection.anthropicEffort == nil else { throw TincallError(message: String(localized: "Anthropic 手动预算不能同时设置自适应强度")) }
                guard let budget = connection.anthropicThinkingBudget, budget >= 1024 else {
                    throw TincallError(message: String(localized: "Anthropic 手动思考预算至少为 1024 Token"))
                }
                let maximum = maxOutputTokens ?? 4096
                guard budget < maximum else {
                    throw TincallError(message: String(localized: "本次输出上限 \(maximum) 必须大于思考预算 \(budget)；摘要使用单独的输出上限，请增加上限或降低预算"))
                }
            }
            if mode != .off, connection.temperature != nil || connection.topP != nil {
                throw TincallError(message: String(localized: "开启 Anthropic 思考时请关闭温度和 Top P 自定义参数"))
            }
        }
        if hasGemini {
            guard connection.geminiThinkingLevel == nil || connection.geminiThinkingBudget == nil else {
                throw TincallError(message: String(localized: "Gemini 思考强度和预算只能选择一种"))
            }
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            if connection.geminiThinkingLevel == .minimal {
                throw TincallError(message: String(localized: "Gemini minimal 的多轮对话需要保留思考签名；当前纯文字历史不支持，请选择其他强度"))
            }
            if connection.geminiThinkingLevel != nil, name.hasPrefix("gemini-2.") || name.hasPrefix("gemini-1.") {
                throw TincallError(message: String(localized: "当前 generateContent 接口的 thinkingLevel 仅用于 Gemini 3 或更新模型；Gemini 2.5 请使用思考预算"))
            }
            if let budget = connection.geminiThinkingBudget {
                guard budget >= -1, budget <= Int(Int32.max) else { throw TincallError(message: String(localized: "Gemini 思考预算须为 -1（动态）、0（关闭）或有效的正整数")) }
                if name.hasPrefix("gemini-3") { throw TincallError(message: String(localized: "Gemini 3 的 generateContent 请求请使用思考强度，不能使用已弃用的思考预算")) }
                if name.hasPrefix("gemini-2.5-pro"), budget != -1, !(128...32_768).contains(budget) {
                    throw TincallError(message: String(localized: "Gemini 2.5 Pro 不能关闭思考；预算应为 -1（动态）或 128 至 32768"))
                }
                if name.hasPrefix("gemini-2.5-flash-lite"), budget != -1, budget != 0, !(512...24_576).contains(budget) {
                    throw TincallError(message: String(localized: "Gemini 2.5 Flash-Lite 预算应为 -1、0 或 512 至 24576"))
                }
                if name.hasPrefix("gemini-2.5-flash"), !name.hasPrefix("gemini-2.5-flash-lite"), budget != -1, !(0...24_576).contains(budget) {
                    throw TincallError(message: String(localized: "Gemini 2.5 Flash 预算应为 -1 或 0 至 24576"))
                }
                if let maximum = maxOutputTokens, budget > 0, budget >= maximum {
                    throw TincallError(message: String(localized: "本次输出上限 \(maximum) 必须大于思考预算 \(budget)，请为最终回复保留输出空间；摘要使用单独上限"))
                }
            }
        }
    }

    nonisolated static func requestBody(connection: ConnectionProfile, messages: [ModelMessage], maxOutputTokens: Int? = nil, stream: Bool = true) throws -> Data {
        try validateParameters(connection, maxOutputTokens: maxOutputTokens)
        guard connection.provider.isLanguageModel, !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messages.isEmpty, messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }) else { throw TincallError(message: String(localized: "模型或对话内容配置无效")) }
        let maximum = maxOutputTokens ?? connection.maxOutputTokens
        for message in messages where message.audio != nil {
            guard connection.provider == .gemini || connection.provider == .openAICompatible else {
                throw TincallError(message: String(localized: "此模型协议尚不支持原声输入"))
            }
            guard message.role == "user", let audio = message.audio, audio.count > 44 else {
                throw TincallError(message: String(localized: "本轮原声录音缺失，未改发识别文字，请重新说话"))
            }
            guard audio.count <= 12 * 1_024 * 1_024 else {
                throw TincallError(message: String(localized: "本段原声录音过长，请分成较短的发言"))
            }
        }
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let conversation = messages.filter { $0.role != "system" }
        guard !conversation.isEmpty else { throw TincallError(message: String(localized: "模型请求缺少用户对话")) }
        var body: [String: Any]
        switch connection.provider {
        case .openAICompatible:
            body = ["model": connection.model.trimmingCharacters(in: .whitespacesAndNewlines), "messages": messages.map { ["role": $0.role, "content": $0.images.isEmpty && $0.audio == nil ? $0.content as Any : $0.contentBlocks(provider: .openAICompatible)] }, "stream": stream, "n": 1]
            if let effort = connection.openAIReasoningEffort { body["reasoning_effort"] = effort.rawValue }
            if let maximum { body[connection.openAIReasoningEffort == nil ? "max_tokens" : "max_completion_tokens"] = maximum }
            if let value = connection.temperature { body["temperature"] = value }
            if let value = connection.topP { body["top_p"] = value }
        case .anthropic:
            body = ["model": connection.model.trimmingCharacters(in: .whitespacesAndNewlines), "messages": conversation.map { ["role": $0.role, "content": $0.images.isEmpty ? $0.content as Any : $0.contentBlocks(provider: .anthropic)] }, "stream": stream, "max_tokens": maximum ?? 4096]
            if !system.isEmpty { body["system"] = system }
            if let value = connection.temperature { body["temperature"] = value }
            if let value = connection.topP { body["top_p"] = value }
            if let mode = connection.anthropicThinkingMode {
                switch mode {
                case .off: body["thinking"] = ["type": "disabled"]
                case .adaptive: body["thinking"] = ["type": "adaptive"]
                case .manual: body["thinking"] = ["type": "enabled", "budget_tokens": connection.anthropicThinkingBudget!]
                }
            }
            if let effort = connection.anthropicEffort { body["output_config"] = ["effort": effort.rawValue] }
        case .gemini:
            body = ["contents": conversation.map { ["role": $0.role == "assistant" ? "model" : "user", "parts": $0.contentBlocks(provider: .gemini)] }]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
            var config: [String: Any] = [:]
            if let maximum { config["maxOutputTokens"] = maximum }
            if let value = connection.temperature { config["temperature"] = value }
            if let value = connection.topP { config["topP"] = value }
            if let level = connection.geminiThinkingLevel { config["thinkingConfig"] = ["thinkingLevel": level.rawValue.uppercased()] }
            if let budget = connection.geminiThinkingBudget { config["thinkingConfig"] = ["thinkingBudget": budget] }
            if !config.isEmpty { body["generationConfig"] = config }
        default: throw TincallError(message: String(localized: "请选择模型协议"))
        }
        let data = try ModelRequestJSON.data(withJSONObject: body)
        if messages.contains(where: { $0.audio != nil }), data.count > 20_000_000 {
            throw TincallError(message: String(localized: "原声请求过大，请缩短发言或减少附带图片"))
        }
        return data
    }

}

/// The wire body and preview share this order; dictionary iteration never determines it.
enum ModelRequestJSON {
    private static let parameterKeys = [
        "model", "stream", "n", "max_tokens", "max_completion_tokens", "temperature", "top_p",
        "reasoning_effort", "thinking", "output_config", "generationConfig", "system", "systemInstruction"
    ]
    private static let fieldKeys = [
        "role", "type", "maxOutputTokens", "temperature", "topP", "thinkingConfig",
        "thinkingLevel", "thinkingBudget", "budget_tokens", "effort", "text",
        "image_url", "url", "image", "source", "inline_data", "media_type", "mime_type", "data",
        "content", "parts"
    ]

    nonisolated static func data(withJSONObject object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw TincallError(message: String(localized: "请求体包含无效的 JSON 值"))
        }
        return Data(try encode(object, depth: 0).utf8)
    }

    private nonisolated static func encode(_ value: Any, depth: Int) throws -> String {
        let indent = String(repeating: "  ", count: depth)
        let childIndent = indent + "  "
        if let object = value as? [String: Any] {
            guard !object.isEmpty else { return "{}" }
            let first = depth == 0 ? parameterKeys : fieldKeys
            let last = depth == 0 ? ["messages", "contents"] : []
            let remaining = object.keys.filter { !first.contains($0) && !last.contains($0) }.sorted()
            let keys = first.filter { object[$0] != nil } + remaining + last.filter { object[$0] != nil }
            let fields = try keys.map { key in
                childIndent + (try scalar(key)) + ": " + (try encode(object[key]!, depth: depth + 1))
            }
            return "{\n" + fields.joined(separator: ",\n") + "\n" + indent + "}"
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[]" }
            let elements = try array.map { childIndent + (try encode($0, depth: depth + 1)) }
            return "[\n" + elements.joined(separator: ",\n") + "\n" + indent + "]"
        }
        return try scalar(value)
    }

    private nonisolated static func scalar(_ value: Any) throws -> String {
        // Preserve Foundation's escaping, numeric precision, boolean/null handling and invalid-value errors.
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
