import Foundation

struct ModelMessage: Codable, Equatable, Sendable {
    enum AudioFormat: String, Codable, Sendable { case wav, mp3 }
    let role: String
    let content: String
    var images: [Data] = []
    /// Current utterance only. Captured WAV is compressed before transmission.
    var audio: Data? = nil
    var audioFormat: AudioFormat? = nil

    func contentBlocks(provider: ConnectionProvider) -> [[String: Any]] {
        var blocks: [[String: Any]] = content.isEmpty ? [] : [provider == .gemini
            ? ["text": content] : ["type": "text", "text": content]]
        for image in images {
            let encoded = image.base64EncodedString()
            switch provider {
            case .anthropic:
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": encoded]])
            case .gemini:
                blocks.append(["inline_data": ["mime_type": "image/jpeg", "data": encoded]])
            default:
                blocks.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + encoded]])
            }
        }
        if let audio {
            if provider == .gemini {
                blocks.append(["inline_data": ["mime_type": "audio/" + (audioFormat ?? .wav).rawValue, "data": audio.base64EncodedString()]])
            } else if provider == .openAICompatible {
                blocks.append(["type": "input_audio", "input_audio": ["format": (audioFormat ?? .wav).rawValue, "data": audio.base64EncodedString()]])
            }
        }
        return blocks
    }

    static func logText(_ messages: [Self]) -> String {
        messages.map { message in
            let attachments = message.images.enumerated().map { index, image in
                String(localized: "[图片 \(index + 1)：JPEG，\(image.count) 字节]")
            }
            let audio = message.audio.map {
                message.audioFormat == .mp3 ? String(localized: "[原声音频：MP3，\($0.count) 字节]")
                    : String(localized: "[原声音频：WAV，\($0.count) 字节]")
            }
            let contents = ([message.content] + attachments + [audio].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n")
            return "[\(message.role)]\n\(contents)"
        }.joined(separator: "\n\n")
    }
}
