// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct FishAudioConfiguration {
    let apiKey: String
    let model: String
    let referenceID: String

    init(apiKey: String, model: String, referenceID: String) throws {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceID = referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !apiKey.utf8.contains(13), !apiKey.utf8.contains(10),
              !apiKey.contains("•"), !apiKey.contains("*"), apiKey != "已配置",
              !model.utf8.contains(13), !model.utf8.contains(10), model.utf8.count <= 256,
              !referenceID.isEmpty, referenceID.utf8.count <= 256,
              !referenceID.utf8.contains(13), !referenceID.utf8.contains(10) else {
            throw TincallError(message: String(localized: "请填写有效的 Fish Audio API Key、模型和声音 Reference ID"))
        }
        self.apiKey = apiKey
        self.model = model.isEmpty ? "s2.1-pro" : model
        self.referenceID = referenceID
    }

    func request(text: String) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TincallError(message: String(localized: "Fish Audio 合成文字为空"))
        }
        var request = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(model, forHTTPHeaderField: "model")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm, application/octet-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "reference_id": referenceID, "format": "pcm", "sample_rate": 24_000
        ])
        return request
    }
}

/// Transport chunks need not end on an Int16 sample boundary.
struct FishPCMStream {
    private var trailingByte: UInt8?
    private var hasAudio = false

    static func validate(statusCode: Int, contentType: String?) throws {
        guard statusCode == 200 else { throw TincallError(message: String(localized: "Fish Audio 合成失败（HTTP \(statusCode)）")) }
        let mime = contentType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mime, ["audio/pcm", "audio/x-pcm", "audio/raw", "application/octet-stream", "binary/octet-stream"].contains(mime) else {
            throw TincallError(message: String(localized: "Fish Audio 未返回请求的原始 PCM 音频，未播放"))
        }
    }

    mutating func consume(_ data: Data) -> Data {
        var pcm = Data()
        if let trailingByte { pcm.append(trailingByte); self.trailingByte = nil }
        pcm.append(data)
        if !pcm.count.isMultiple(of: 2) { trailingByte = pcm.removeLast() }
        if !pcm.isEmpty { hasAudio = true }
        return pcm
    }

    func finish() throws {
        guard hasAudio else { throw TincallError(message: String(localized: "Fish Audio 返回了空音频")) }
        guard trailingByte == nil else { throw TincallError(message: String(localized: "Fish Audio PCM 音频不完整")) }
    }
}
