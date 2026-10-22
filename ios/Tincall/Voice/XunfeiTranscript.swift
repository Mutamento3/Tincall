// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct XunfeiTranscript {
    private var segments: [Int: String] = [:]
    private(set) var usesDynamicCorrections = false

    mutating func consume(_ data: Data) throws -> (text: String, isFinal: Bool)? {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.code == 0 else {
            throw TincallError(message: String(localized: "讯飞识别失败（\(response.code)）"), requestCode: String(response.code))
        }
        guard let payload = response.data else { return nil }
        if let result = payload.result {
            if result.pgs == "apd" || result.pgs == "rpl" { usesDynamicCorrections = true }
            let text = (result.ws ?? []).compactMap { $0.cw.first?.w }.joined()
            // Apply a replacement atomically; an empty end marker cannot erase speech.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if result.pgs == "rpl", let range = result.rg, range.count == 2 {
                    segments = segments.filter { $0.key < range[0] || $0.key > range[1] }
                }
                segments[result.sn] = text
            }
        }
        let text = segments.keys.sorted().compactMap { segments[$0] }.joined()
        let isFinal = payload.status == 2
        return text.isEmpty && !isFinal ? nil : (text, isFinal)
    }

    private struct Response: Decodable {
        let code: Int
        let message: String?
        let data: Payload?
    }
    private struct Payload: Decodable {
        let status: Int
        let result: Result?
    }
    private struct Result: Decodable {
        let sn: Int
        let pgs: String?
        let rg: [Int]?
        let ws: [Word]?
    }
    private struct Word: Decodable { let cw: [Candidate] }
    private struct Candidate: Decodable { let w: String }
}

// Only the current uncommitted recognition session is retained for provider fallback.
struct STTReplayBuffer {
    private(set) var audio = Data()
    /// Xunfei replays stay within its 60-second session; Apple keeps a whole utterance (up to 10 minutes).
    var limitBytes = 16_000 * 2 * 70
    mutating func append(_ pcm: Data) throws {
        guard audio.count + pcm.count <= limitBytes else {
            throw TincallError(message: String(localized: "语音识别等待过久，请重新打开麦克风"))
        }
        audio.append(pcm)
    }
    mutating func take(after sentBytes: Int = 0) -> Data {
        let remainder = Data(audio.dropFirst(sentBytes))
        audio.removeAll(keepingCapacity: true)
        return remainder
    }
}
