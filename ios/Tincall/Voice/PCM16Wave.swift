// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

enum PCM16Wave {
    /// Int16 little-endian, mono PCM. Both retained clips and uploads use this container.
    static func data(pcm: Data, sampleRate: UInt32) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); word(UInt32(36 + pcm.count)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(sampleRate)
        word(sampleRate * 2); word(UInt16(2)); word(UInt16(16))
        ascii("data"); word(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
