import Foundation

struct WhisperConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let language: String?
    let apiKey: String?

    init(endpoint: URL?, model: String, language: String?, apiKey: String?) throws {
        guard var endpoint, endpoint.scheme?.lowercased() == "https", endpoint.host?.isEmpty == false,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw TincallError(message: String(localized: "Whisper 兼容服务需要不含凭据或查询参数的 HTTPS 地址"))
        }
        let path = endpoint.path.split(separator: "/").map(String.init)
        if Array(path.suffix(2)) != ["audio", "transcriptions"] {
            if path.last != "v1" { endpoint.appendPathComponent("v1") }
            endpoint.appendPathComponent("audio/transcriptions")
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.utf8.contains(13), !model.utf8.contains(10), model.utf8.count <= 256 else {
            throw TincallError(message: String(localized: "Whisper 模型名称无效"))
        }
        let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard language.isEmpty || (language.utf8.count == 2 && language.utf8.allSatisfy { (97...122).contains($0) }) else {
            throw TincallError(message: String(localized: "Whisper 语言请使用两位 ISO 639-1 代码，如 zh 或 en；留空自动识别"))
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.utf8.contains(13), !key.utf8.contains(10), !key.contains("•"), !key.contains("*"), key != "已配置" else {
            throw TincallError(message: String(localized: "Whisper API Key 无效；无需鉴权的服务可留空"))
        }
        self.endpoint = endpoint
        self.model = model.isEmpty ? "whisper-1" : model
        self.language = language.isEmpty ? nil : language
        self.apiKey = key.isEmpty ? nil : key
    }

    func request(pcm: Data) throws -> URLRequest {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= WhisperUtteranceBuffer.maximumBytes else {
            throw TincallError(message: String(localized: "Whisper 语音片段为空、不完整或过长"))
        }
        let boundary = "Tincall-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(contentsOf: value.utf8) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("response_format", "json")
        if let language { field("language", language) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(PCM16Wave.data(pcm: pcm, sampleRate: 16_000))
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

enum WhisperTranscription {
    static let maximumResponseBytes = 1_048_576

    static func text(from data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            throw TincallError(message: String(localized: "Whisper 转写失败（HTTP \(statusCode)）"))
        }
        guard data.count <= maximumResponseBytes else { throw TincallError(message: String(localized: "Whisper 转写响应过大")) }
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TincallError(message: String(localized: "Whisper 服务未返回有效的 JSON 转写正文"))
        }
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// VAD-filtered audio is sent only after an utterance boundary, never as a fake stream.
struct WhisperUtteranceBuffer {
    // Only a pause ends an utterance; 10 minutes is a safety cap under the 25 MB upload limit.
    // One capture packet can cross the cap.
    static let maximumBytes = 16_000 * 2 * 601
    static let utteranceLimitBytes = 16_000 * 2 * 600
    static let silenceLimitBytes = 16_000 * 2 * 2
    private(set) var audio = Data()
    private var silenceBytes = 0

    mutating func append(_ pcm: Data, hasSpeech: Bool) throws -> Data? {
        guard pcm.count.isMultiple(of: 2), pcm.count <= 16_000 * 2 else {
            throw TincallError(message: String(localized: "Whisper 收音格式无效"))
        }
        guard hasSpeech || !audio.isEmpty else { return nil }
        audio.append(pcm)
        silenceBytes = hasSpeech ? 0 : silenceBytes + pcm.count
        guard silenceBytes >= Self.silenceLimitBytes || audio.count >= Self.utteranceLimitBytes else { return nil }
        let result = audio
        audio = Data(); silenceBytes = 0
        return result
    }
}

/// Keep subsequent speech while the prior file is being transcribed. Emit a final
/// only when every captured utterance is resolved, before Core starts playback.
struct WhisperInputBuffer {
    private var utterance = WhisperUtteranceBuffer()
    private var pending: [Data] = []
    private var uploading = Data()
    private var recognizedText: [String] = []
    private var recognizedAudio = Data()

    var currentAudio: Data { recognizedAudio + uploading + pending.reduce(Data(), +) + utterance.audio }

    mutating func append(_ pcm: Data, hasSpeech: Bool) throws {
        if let completed = try utterance.append(pcm, hasSpeech: hasSpeech) { pending.append(completed) }
        guard recognizedAudio.count + uploading.count + utterance.audio.count + pending.reduce(0, { $0 + $1.count }) <= 16_000 * 2 * 120 else {
            throw TincallError(message: String(localized: "Whisper 转写跟不上收音，请等待或重新打开麦克风"))
        }
    }

    mutating func next() -> Data? {
        guard uploading.isEmpty, !pending.isEmpty else { return nil }
        uploading = pending.removeFirst()
        return uploading
    }

    mutating func finishRecording() {
        if !utterance.audio.isEmpty { pending.append(utterance.audio) }
        utterance = WhisperUtteranceBuffer()
    }

    mutating func complete(text: String) -> (text: String, pcm: Data)? {
        guard !uploading.isEmpty else { return nil }
        if !text.isEmpty { recognizedText.append(text) }
        recognizedAudio.append(uploading)
        uploading = Data()
        guard pending.isEmpty, utterance.audio.isEmpty else { return nil }
        let result = (text: recognizedText.joined(separator: "\n"), pcm: recognizedAudio)
        recognizedText.removeAll(); recognizedAudio = Data()
        return result
    }
}
