import Foundation

/// Provider time ranges identify corrections; equal text spoken twice is retained.
struct TimedSpeechTranscript {
    private struct Part {
        let start: Double
        let end: Double
        let text: String
        let isFinal: Bool
    }
    private var parts: [Part] = []
    var text: String { parts.sorted { $0.start < $1.start }.map(\.text).joined() }

    mutating func update(start: Double, end: Double, text: String, isFinal: Bool) {
        guard start.isFinite, end.isFinite, end >= start else { return }
        // A final range cannot be replaced by a late volatile callback.
        guard !parts.contains(where: { $0.isFinal && $0.start == start && !isFinal }) else { return }
        parts.removeAll { part in
            part.start == start || (!part.isFinal && part.start < end && part.end > start)
        }
        parts.append(Part(start: start, end: end, text: text, isFinal: isFinal))
    }
}
