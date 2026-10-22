import Foundation

struct SpeechGate {
    private var preRoll = Data()
    private var tailFrames = 0

    mutating func filter(_ frame: Data, speechProbability: Float) -> (audio: Data, hasSpeech: Bool) {
        let speech = speechProbability >= 0.5
        // Open on the first positive frame. Lower hysteresis threshold keeps quiet
        // syllables; 320 ms hangover keeps word endings without delaying upload.
        if speech || (tailFrames > 0 && speechProbability >= 0.35) {
            tailFrames = 10
            let audio = preRoll + frame
            preRoll.removeAll(keepingCapacity: true)
            return (audio, speech)
        }
        if tailFrames > 0 {
            tailFrames -= 1
            return (frame, false)
        }
        preRoll.append(frame)
        if preRoll.count > 5_120 { preRoll.removeFirst(preRoll.count - 5_120) }
        // Keep the provider's streaming clock alive without sending background
        // noise. Keep real onset audio in pre-roll until speech is detected.
        return (Data(repeating: 0, count: frame.count), false)
    }
}
