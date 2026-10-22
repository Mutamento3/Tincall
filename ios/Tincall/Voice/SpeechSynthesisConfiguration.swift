import Foundation

struct ElevenLabsConfiguration {
    let elevenLabsAPIKey: String
    let elevenLabsVoiceID: String
    let elevenLabsModel: String

    var supportsRequestStitching: Bool {
        ["eleven_v4", "eleven_v4_turbo"].contains(elevenLabsModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct MiniMaxConfiguration {
    let apiKey: String
    let model: String
    let voiceID: String
    let endpoint: URL
}

enum SpeechSynthesisConfiguration {
    case elevenLabs(ElevenLabsConfiguration)
    case miniMax(MiniMaxConfiguration)
    case fishAudio(FishAudioConfiguration)
}
