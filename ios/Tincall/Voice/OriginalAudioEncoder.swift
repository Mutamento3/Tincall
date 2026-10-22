import Foundation
import LAME

/// Upload encoding only. Input is the mono PCM16 WAV produced by PCM16Wave.
enum OriginalAudioEncoder {
    static func mp3(wave: Data) throws -> Data {
        try Task.checkCancellation()
        guard wave.count > 44, wave.count <= 12 * 1_024 * 1_024, (wave.count - 44).isMultiple(of: 2) else {
            throw encodingError()
        }
        let header = [UInt8](wave.prefix(44))
        func word(_ offset: Int, _ bytes: Int) -> UInt32 {
            (0..<bytes).reduce(0) { $0 | UInt32(header[offset + $1]) << ($1 * 8) }
        }
        guard String(bytes: header[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: header[8..<16], encoding: .ascii) == "WAVEfmt ",
              String(bytes: header[36..<40], encoding: .ascii) == "data",
              word(16, 4) == 16, word(20, 2) == 1, word(22, 2) == 1,
              word(24, 4) == 16_000, word(28, 4) == 32_000,
              word(32, 2) == 2, word(34, 2) == 16,
              word(4, 4) == UInt32(wave.count - 8), word(40, 4) == UInt32(wave.count - 44),
              let encoder = lame_init() else { throw encodingError() }
        defer { lame_close(encoder) }
        guard lame_set_num_channels(encoder, 1) == 0,
              lame_set_in_samplerate(encoder, 16_000) == 0,
              lame_set_out_samplerate(encoder, 16_000) == 0,
              lame_set_brate(encoder, 48) == 0,
              lame_set_mode(encoder, MONO) == 0,
              lame_set_quality(encoder, 2) == 0,
              lame_set_bWriteVbrTag(encoder, 0) == 0,
              lame_init_params(encoder) == 0 else { throw encodingError() }

        var samples = [Int16](repeating: 0, count: (wave.count - 44) / 2)
        _ = samples.withUnsafeMutableBytes { wave.copyBytes(to: $0, from: 44..<wave.count) }
        let chunkSize = 4_096
        // LAME's documented worst-case output bound: 1.25 * samples + 7200.
        var buffer = [UInt8](repeating: 0, count: chunkSize * 5 / 4 + 7_200)
        var result = Data()
        try samples.withUnsafeBufferPointer { input in
            for offset in stride(from: 0, to: samples.count, by: chunkSize) {
                try Task.checkCancellation()
                let count = min(chunkSize, samples.count - offset)
                let written = buffer.withUnsafeMutableBufferPointer { output in
                    lame_encode_buffer(encoder, input.baseAddress! + offset, input.baseAddress! + offset,
                        Int32(count), output.baseAddress, Int32(output.count))
                }
                guard written >= 0 else { throw encodingError() }
                result.append(contentsOf: buffer.prefix(Int(written)))
            }
        }
        try Task.checkCancellation()
        let written = buffer.withUnsafeMutableBufferPointer {
            lame_encode_flush(encoder, $0.baseAddress, Int32($0.count))
        }
        guard written >= 0 else { throw encodingError() }
        result.append(contentsOf: buffer.prefix(Int(written)))
        guard !result.isEmpty else { throw encodingError() }
        return result
    }

    private static func encodingError() -> TincallError {
        TincallError(message: String(localized: "原声录音无法编码为 MP3，请重新说话"), requestCode: "audio_encoding_failed")
    }
}
