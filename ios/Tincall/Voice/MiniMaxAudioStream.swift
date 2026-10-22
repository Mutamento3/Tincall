// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// MiniMax requests exclude the final aggregate; only status 1 carries new PCM.
struct MiniMaxAudioStream {
    private(set) var complete = false
    private var receivedAudio = false

    mutating func consume(line: String) throws -> Data? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix(":"), !line.hasPrefix("event:"), !line.hasPrefix("id:") else { return nil }
        let payload = line.hasPrefix("data:") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : line
        if payload == "[DONE]" { return nil }
        let response = try JSONDecoder().decode(Response.self, from: Data(payload.utf8))
        if let status = response.base_resp?.status_code, status != 0 {
            throw TincallError(message: String(localized: "MiniMax 合成失败（\(status)）"), requestCode: String(status))
        }
        if let info = response.extra_info {
            guard info.audio_sample_rate == nil || info.audio_sample_rate == 24000,
                  info.audio_channel == nil || info.audio_channel == 1,
                  info.audio_format == nil || info.audio_format == "pcm" else {
                throw TincallError(message: String(localized: "MiniMax 返回的音频格式与请求不一致"))
            }
        }
        guard let data = response.data, let status = data.status else { return nil }
        if complete { return nil }
        if status == 2 {
            complete = true
            // With exclude_aggregated_audio=true this contains only metadata.
            // Never append a whole-response aggregate to already played chunks.
            if let audio = data.audio, !audio.isEmpty, !receivedAudio {
                let pcm = try Self.decodeHex(audio)
                receivedAudio = !pcm.isEmpty
                return pcm
            }
            return nil
        }
        guard status == 1 else { throw TincallError(message: String(localized: "MiniMax 返回了未知音频状态")) }
        guard let audio = data.audio, !audio.isEmpty else { return nil }
        let pcm = try Self.decodeHex(audio)
        receivedAudio = receivedAudio || !pcm.isEmpty
        return pcm
    }

    func finish() throws {
        guard complete, receivedAudio else { throw TincallError(message: String(localized: "MiniMax 音频流未完整结束")) }
    }

    private static func decodeHex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count <= 2 * 1024 * 1024 else {
            throw TincallError(message: String(localized: "MiniMax 音频编码无效"))
        }
        func digit(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 65 + 10
            case 97...102: return value - 97 + 10
            default: return nil
            }
        }
        var result = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = digit(bytes[index]), let low = digit(bytes[index + 1]) else {
                throw TincallError(message: String(localized: "MiniMax 音频编码无效"))
            }
            result.append(high * 16 + low)
        }
        return result
    }

    private struct Response: Decodable { let data: Audio?; let base_resp: Status?; let extra_info: AudioInfo? }
    private struct Audio: Decodable { let audio: String?; let status: Int? }
    private struct Status: Decodable { let status_code: Int }
    private struct AudioInfo: Decodable { let audio_sample_rate: Int?; let audio_channel: Int?; let audio_format: String? }
}
