import Foundation

struct SpeechSegment {
    let text: String
    /// Display only this segment's original words, without synthesis controls.
    let caption: String
    let sourceEnd: Int
    let bodyCount: Int
}

/// Accepts only new text. Final snapshots are reconciled by CallCoordinator.
/// Only documented supplier markers are kept atomic across text deltas.
struct SpeechSegmenter {
    private struct Token {
        let raw: String
        let bodyCount: Int
        let pause: Bool
        let sentenceEnd: Bool
        let cue: String?
        var protectedPoint = false
        var silence = false
        var speakable: Bool { cue == nil && !silence && raw.contains { $0.isLetter || $0.isNumber } }
    }

    private var buffer = ""
    private var sourceEnd = 0
    private var finished = false
    private var emittedCount = 0
    private let tagsEnabled: Bool
    private let miniMax: Bool
    private let miniMaxTags: Bool
    private let fishTags: Bool
    private var expressionCues: [String] = []
    private(set) var droppedIncompleteTags = 0

    init(tagsEnabled: Bool = false, miniMax: Bool = false, miniMaxTags: Bool = false, fishTags: Bool = false) {
        self.tagsEnabled = tagsEnabled; self.miniMax = miniMax; self.miniMaxTags = miniMaxTags; self.fishTags = fishTags
    }

    init(provider: ConnectionProvider, model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(tagsEnabled: provider == .elevenLabs && ["eleven_v3", "eleven_v4", "eleven_v4_turbo"].contains(model),
                  miniMax: provider == .miniMax,
                  miniMaxTags: provider == .miniMax && ["speech-2.8-hd", "speech-2.8-turbo"].contains(model),
                  fishTags: provider == .fishAudio && ["s2.1-pro", "s2.1-pro-free", "s2-pro"].contains(model))
    }

    /// Presentation only: keep the original model/TTS text unchanged.
    static func displayText(_ text: String, provider: ConnectionProvider, model: String, isStreaming: Bool) -> String {
        var parser = SpeechSegmenter(provider: provider, model: model)
        parser.buffer = text
        // Display parsing never rejects malformed controls; final incomplete
        // markers remain literal, while a streaming marker waits for its end.
        guard let tokens = try? parser.tokenize(final: !isStreaming, forDisplay: true) else { return text }
        return presentationText(tokens)
    }

    /// Remove control-only lines and normalize ASCII spaces touching controls.
    /// Preserve authored blank lines and indentation on lines containing text.
    private static func presentationText(_ tokens: [Token]) -> String {
        var result = ""
        var line = ""
        var index = 0
        var hasLineText = false
        var hasLineControl = false
        while index < tokens.count {
            let token = tokens[index]
            if token.cue != nil || token.silence || token.raw == " " {
                var removedControl = false
                var spaces = ""
                var indentation = ""
                while index < tokens.count {
                    let next = tokens[index]
                    if next.cue != nil || next.silence {
                        removedControl = true
                        hasLineControl = true
                    } else if next.raw == " " {
                        spaces += " "
                        if !removedControl { indentation += " " }
                    } else { break }
                    index += 1
                }
                if !removedControl {
                    line += spaces
                } else if !hasLineText {
                    line += indentation
                } else if !spaces.isEmpty, index < tokens.count,
                          tokens[index].raw.first?.isNewline == false {
                    line += " "
                }
            } else {
                if token.raw.last?.isNewline == true {
                    if hasLineText || !hasLineControl { result += line + token.raw }
                    line = ""
                    hasLineText = false
                    hasLineControl = false
                } else {
                    line += token.raw
                    if token.raw.contains(where: { !$0.isWhitespace }) { hasLineText = true }
                }
                index += 1
            }
        }
        if hasLineText || !hasLineControl { result += line }
        return result
    }

    mutating func append(_ text: String, final: Bool) throws -> [SpeechSegment] {
        guard !finished else { return [] }
        buffer += text
        var output: [SpeechSegment] = []
        while !buffer.isEmpty {
            let tokens = try tokenize(final: final)
            if miniMax { try validatePauses(tokens, final: final) }
            var count = 0
            var cut: Int?
            var lastPause: Int?
            var scopedExpression = !expressionCues.isEmpty
            var closesExpression = false
            for (index, token) in tokens.enumerated() {
                if count + token.bodyCount > 48 {
                    // Never cut on a point/ellipsis token, including at the cap.
                    cut = ([lastPause].compactMap { $0 } + Array((1...max(1, index)).reversed())).first {
                        $0 > 0 && !tokens[$0 - 1].protectedPoint && safeBoundary($0, in: tokens, final: final)
                    }
                    if cut != nil { break }
                }
                if Self.isExpression(token.cue) { scopedExpression = true }
                count += token.bodyCount
                if token.pause { lastPause = index + 1 }
                let firstBoundary = emittedCount == 0 &&
                    (token.sentenceEnd || (count >= 12 && "，,：:".contains(token.raw)))
                let laterBoundary = emittedCount > 0 && count > 20 && token.pause
                if count > 0, (firstBoundary || laterBoundary || (token.sentenceEnd && scopedExpression)), safeBoundary(index + 1, in: tokens, final: final) {
                    closesExpression = token.sentenceEnd && scopedExpression
                    cut = index + 1; break
                }
                if count >= 48, !token.protectedPoint, safeBoundary(index + 1, in: tokens, final: final) {
                    cut = index + 1; break
                }
            }
            if let boundary = cut, final, emittedCount > 0, !closesExpression {
                let tailCount = tokens.dropFirst(boundary).reduce(0) { $0 + $1.bodyCount }
                let total = tokens.reduce(0) { $0 + $1.bodyCount }
                if tailCount < 21, total <= 48 { cut = tokens.count }
            }
            if cut == nil, final, !tokens.isEmpty { cut = tokens.count }
            guard let cut, cut > 0 else { break }
            let chosen = Array(tokens.prefix(cut))
            let raw = chosen.map(\.raw).joined()
            buffer.removeFirst(raw.count)
            sourceEnd += raw.unicodeScalars.count
            let bodyCount = chosen.reduce(0) { $0 + $1.bodyCount }
            // A new adjacent group replaces the whole previous group. Only length
            // splits inside the same sentence inherit it; events stay at source.
            let firstContent = chosen.first { !$0.raw.allSatisfy(\.isWhitespace) }
            let prefix = Self.isExpression(firstContent?.cue) ? "" : expressionCues.joined()
            var inGroup = false
            for token in chosen {
                if Self.isExpression(token.cue) {
                    if !inGroup { expressionCues.removeAll() }
                    expressionCues.append(token.raw)
                    inGroup = true
                } else if !token.raw.allSatisfy(\.isWhitespace) {
                    inGroup = false
                }
                if token.sentenceEnd { expressionCues.removeAll(); inGroup = false }
            }
            // One-shot cues remain in their original segment; never prefix them again.
            if bodyCount > 0 || chosen.contains(where: { token in
                guard let cue = token.cue else { return false }
                return !Self.delivery.contains(cue) && !Self.emotions.contains(cue)
            }) {
                let caption = Self.presentationText(chosen).trimmingCharacters(in: .whitespacesAndNewlines)
                emittedCount += 1
                output.append(SpeechSegment(text: prefix + raw, caption: caption, sourceEnd: sourceEnd, bodyCount: bodyCount))
            }
        }
        finished = final
        return output
    }

    private static func isExpression(_ cue: String?) -> Bool {
        guard let cue else { return false }
        return delivery.contains(cue) || emotions.contains(cue)
    }

    private static let delivery: Set<String> = ["whispers", "whispering", "shouting"]
    private static let emotions: Set<String> = ["excited", "sad", "angry", "curious", "sarcastic", "mischievously", "crying"]
    private static let miniMaxEvents: Set<String> = ["laughs", "chuckle", "coughs", "clear-throat", "groans", "breath", "pant", "inhale", "exhale", "gasps", "sniffs", "sighs", "snorts", "burps", "lip-smacking", "humming", "hissing", "emm", "sneezes"]

    private func safeBoundary(_ boundary: Int, in tokens: [Token], final: Bool) -> Bool {
        guard miniMax else { return true }
        // Keep both sides of each pause in one request, including punctuation
        // between the preceding words and a pause received in the next delta.
        if tokens[..<boundary].last(where: { $0.speakable || $0.silence })?.silence == true { return false }
        if let next = tokens[boundary...].first(where: { $0.speakable || $0.silence }) { return !next.silence }
        return final
    }

    private func validatePauses(_ tokens: [Token], final: Bool) throws {
        var hasText = false
        var pendingPause = false
        for token in tokens {
            if token.silence {
                guard hasText else { throw TincallError(message: String(localized: "MiniMax 停顿必须位于两段正文之间，不能连续使用")) }
                hasText = false; pendingPause = true
            } else if token.speakable { hasText = true; pendingPause = false }
        }
        if final, pendingPause { throw TincallError(message: String(localized: "MiniMax 停顿后需要有正文，不能放在结尾")) }
    }

    private static func validPauseDuration(_ duration: String) -> Bool {
        let parts = duration.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || parts[1].count <= 2,
              let value = Double(duration), (0.01...99.99).contains(value) else { return false }
        return true
    }

    private mutating func tokenize(final: Bool, forDisplay: Bool = false) throws -> [Token] {
        let chars = Array(buffer)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if tagsEnabled || fishTags, character == "[" {
                if let end = chars[(index + 1)...].firstIndex(of: "]") {
                    let cue = String(chars[(index + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cue.contains("[") {
                        tokens.append(Token(raw: String(chars[index...end]), bodyCount: 0, pause: false, sentenceEnd: false, cue: cue))
                        index = end + 1
                        continue
                    }
                } else {
                    if final, !forDisplay {
                        buffer = String(chars[..<index])
                        droppedIncompleteTags += 1
                    }
                    if !final || !forDisplay { break }
                }
            }
            if miniMax, character == "<", index + 1 < chars.count, chars[index + 1] == "#" {
                if let end = chars[(index + 2)...].firstIndex(of: ">"), end >= index + 4, end - index <= 16,
                   chars[end - 1] == "#" {
                    let duration = String(chars[(index + 2)..<(end - 1)])
                    if Self.validPauseDuration(duration) {
                        tokens.append(Token(raw: String(chars[index...end]), bodyCount: 0, pause: false, sentenceEnd: false, cue: nil, silence: true))
                        index = end + 1
                        continue
                    }
                } else if !final, chars.count - index <= 16 { break }
                if !forDisplay {
                    throw TincallError(message: String(localized: "MiniMax 停顿应为 <#秒数#>，范围 0.01–99.99，最多两位小数"))
                }
            }
            if miniMaxTags, character == "(" {
                if let end = chars[(index + 1)...].firstIndex(of: ")"), end - index <= 64 {
                    let cue = String(chars[(index + 1)..<end]).lowercased()
                    if Self.miniMaxEvents.contains(cue) {
                        tokens.append(Token(raw: String(chars[index...end]), bodyCount: 0, pause: false, sentenceEnd: false, cue: cue))
                        index = end + 1
                        continue
                    }
                } else if !final, chars.count - index <= 64 { break }
            }
            if character == "." || character == "…" {
                var end = index + 1
                while end < chars.count, chars[end] == "." || chars[end] == "…" { end += 1 }
                if end == chars.count, !final, !forDisplay { break }
                tokens.append(Token(raw: String(chars[index..<end]), bodyCount: end - index,
                                    pause: false, sentenceEnd: false, cue: nil, protectedPoint: true))
                index = end
                continue
            }
            let sentenceEnd = "。！？!?\n".contains(character)
            let pause = sentenceEnd || "，,：:；;".contains(character)
            tokens.append(Token(raw: String(character), bodyCount: character.isWhitespace ? 0 : 1,
                                pause: pause, sentenceEnd: sentenceEnd, cue: nil))
            index += 1
        }
        return tokens
    }
}
