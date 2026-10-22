import Foundation

protocol RequestLogCodedError: Error { var requestCode: String? { get } }
extension TincallError: RequestLogCodedError {}

enum RequestLogService: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI 兼容模型", anthropic = "Anthropic", gemini = "Gemini"
    case apple = "Apple", xunfei = "讯飞", bailian = "百炼", whisper = "Whisper"
    case miniMax = "MiniMax", elevenLabs = "ElevenLabs", fish = "Fish Audio"
    case cloud = "云端同步", backend = "外部后端", mcp = "MCP"
    var id: String { rawValue }
    var displayName: String { String(localized: String.LocalizationValue(rawValue)) }

    static func model(_ provider: ConnectionProvider) -> Self {
        switch provider {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        default: return .openAI
        }
    }
}

enum RequestLogStep: String, Codable, Sendable {
    case transcription = "转写", model = "模型", synthesis = "合成"
    case summary = "摘要", models = "模型列表", connectionTest = "连接测试"
    case sync = "云端同步", callControl = "通话管理", events = "接收回复"
    case capabilities = "连接能力", roleRegistration = "角色注册", device = "设备绑定", schedule = "定时来电"
    var displayName: String {
        // Preserve the stored value so previously saved logs still decode.
        self == .roleRegistration ? String(localized: "联系人登记") : String(localized: String.LocalizationValue(rawValue))
    }
}

struct RequestLogContext: Codable, Equatable, Sendable {
    let callID: UUID
    var roundID: UUID? = nil
}

struct RequestLogRound: Codable, Identifiable, Sendable {
    let id: UUID
    var turnID: UUID?
}

struct RequestLogCall: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var rounds: [RequestLogRound] = []
    var mode: CallMode? = nil
}

struct RequestLogEntry: Codable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable { case pending, succeeded, failed, cancelled }
    let id: UUID
    let time: Date
    let service: RequestLogService
    let step: RequestLogStep
    let context: RequestLogContext?
    let segment: Int?
    var duration: TimeInterval?
    var outcome: Outcome = .pending
    var httpStatus: Int?
    var errorCode: String?
    var connectionName: String? = nil
    var modelName: String? = nil
    var requestText: String? = nil
    var requestBodyJSON: String? = nil
    var omittedTurnCount: Int? = nil
    /// Character offset in the redacted request text, after all system messages.
    var requestConversationOffset: Int? = nil
    var responseText: String? = nil
    var reasoningText: String? = nil
    var serverErrorText: String? = nil
}

enum RequestLogCategory: String, CaseIterable, Identifiable {
    case all = "全部请求", chat = "聊天模型", summary = "摘要模型"
    case stt = "语音识别 STT", tts = "语音合成 TTS", connection = "同步与连接"
    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

extension RequestLogEntry {
    var displayModelName: String? {
        if service == .apple, step == .transcription {
            return String(localized: "Apple 本机识别")
        }
        return modelName
    }

    var displayConnectionName: String? {
        guard step == .transcription else { return connectionName }
        switch (service, connectionName) {
        case (.apple, "Apple 本机识别"), (.apple, "Apple On-Device Recognition"):
            return String(localized: "Apple 本机识别")
        case (.xunfei, "讯飞"): return String(localized: "讯飞")
        case (.xunfei, "讯飞识别"): return String(localized: "讯飞识别")
        case (.bailian, "百炼"): return String(localized: "百炼")
        case (.bailian, "百炼识别"): return String(localized: "百炼识别")
        case (.whisper, "Whisper 兼容"): return String(localized: "Whisper 兼容")
        default: return connectionName
        }
    }

    var category: RequestLogCategory {
        switch step {
        case .model: [.openAI, .anthropic, .gemini].contains(service) ? .chat : .connection
        case .summary: [.openAI, .anthropic, .gemini].contains(service) ? .summary : .connection
        case .transcription: .stt
        case .synthesis: .tts
        default: .connection
        }
    }

}
