// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFAudio
import Foundation

@main
struct OriginalAudioEncodingChecks {
    static func main() async throws {
        let sampleCount = 16_000 * 30
        let samples = (0..<sampleCount).map { Int16(12_000 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let wave = PCM16Wave.data(pcm: pcm, sampleRate: 16_000)
        let start = ProcessInfo.processInfo.systemUptime
        let mp3 = try await Task.detached { try OriginalAudioEncoder.mp3(wave: wave) }.value
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(mp3.count < wave.count / 4, "Upload should shrink substantially")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TincallEncodingCheck-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try mp3.write(to: file)
        let decoded = try AVAudioFile(forReading: file)
        precondition(decoded.processingFormat.channelCount == 1 && decoded.processingFormat.sampleRate == 16_000)
        let duration = Double(decoded.length) / decoded.processingFormat.sampleRate
        precondition(abs(duration - 30) < 0.2, "Encoder flush must retain the complete utterance")
        let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length))!
        try decoded.read(into: buffer)
        let samplesOut = buffer.floatChannelData![0]
        let endEnergy = (Int(buffer.frameLength) - 3_200..<Int(buffer.frameLength)).reduce(0.0) {
            $0 + Double(abs(samplesOut[$1]))
        }
        precondition(endEnergy / 3_200 > 0.01, "The last voiced samples must remain audible")
        var invalidHeader = wave
        invalidHeader[22] = 2
        for invalid in [Data(), invalidHeader, Data(wave.dropLast())] {
            do {
                _ = try OriginalAudioEncoder.mp3(wave: invalid)
                preconditionFailure("Invalid input must fail without sending mislabeled audio")
            } catch is TincallError { }
        }
        let cancelled = Task { try OriginalAudioEncoder.mp3(wave: wave) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled encoding must not produce an upload")
        } catch is CancellationError { }
        print("PASS: 30 seconds WAV \(wave.count) bytes -> MP3 \(mp3.count) bytes; encoding \(Int(elapsed * 1_000)) ms; decodable mono audio, complete tail, invalid-input rejection and cancellation")
    }
}
