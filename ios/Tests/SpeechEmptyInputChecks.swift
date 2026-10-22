import Foundation

/// Exercises the real HTTP receive/queue path with synthetic error responses.
/// All responses are JSON errors: this check never renders audio or opens input.
private final class EmptySpeechProtocol: URLProtocol, @unchecked Sendable {
    static let contextRequests = CapturedSpeechRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-context" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.contextRequests.append(data)
        }
        let code = request.value(forHTTPHeaderField: "xi-api-key") == "synthetic-quota" ? "quota_exceeded" : "input_text_empty"
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"detail\":{\"status\":\"\(code)\",\"message\":\"Synthetic error\"}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CapturedSpeechRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func append(_ body: Data) { lock.withLock { bodies.append(body) } }
    var all: [Data] { lock.withLock { bodies } }
}

@main
struct SpeechEmptyInputChecks {
    @MainActor static func main() async throws {
        // A stuck queue must fail this check rather than wait indefinitely.
        let deadline = Task {
            try await Task.sleep(for: .seconds(8))
            fatalError("empty-input queue did not finish")
        }
        defer { deadline.cancel() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmptySpeechProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for text in ["🙂", "1️⃣", "🅰️", "🅰", "…", "[exhales sharply]", "[whispers]🙂"] {
            let playback = try makePlayback(session)
            try playback.appendText(text, final: true)
            do { try await playback.waitUntilFinished() }
            catch { fatalError("non-speech input incorrectly failed the reply: \(text)") }
            precondition(playback.synthesisError == nil && playback.failedCaption == nil)
            precondition(!playback.isActive && !playback.isPlaying)
        }
        // The provider's empty-input code must not hide the loss of real words.
        for text in ["确实有内容。", "Hello.", "123。", "[whispers]有正文🙂。"] {
            let playback = try makePlayback(session)
            try playback.appendText(text, final: true)
            var failed = false
            do { try await playback.waitUntilFinished() } catch { failed = true }
            precondition(failed && playback.synthesisError != nil, "spoken text must still report synthesis failure")
        }
        let quota = try makePlayback(session, key: "synthetic-quota")
        try quota.appendText("🙂", final: true)
        var quotaFailed = false
        do { try await quota.waitUntilFinished() } catch { quotaFailed = true }
        precondition(quotaFailed, "other provider failures must not be suppressed")

        let queue = try makePlayback(session)
        try queue.appendText("🙂。", final: false)
        try queue.appendText("[exhales sharply]🙂", final: true)
        try await queue.waitUntilFinished()
        let entry = RequestLogStore.shared.entries.last { $0.service == .elevenLabs }
        precondition(entry?.outcome == .failed && entry?.errorCode == "input_text_empty",
                     "the original HTTP failure remains diagnosable in request logs")

        let mixed = try makePlayback(session)
        try mixed.appendText("🙂。", final: false)
        try mixed.appendText("确实有内容。", final: true)
        var mixedFailed = false
        do { try await mixed.waitUntilFinished() } catch { mixedFailed = true }
        precondition(mixedFailed && mixed.failedCaption == "确实有内容。",
                     "skipping an empty segment must preserve failure reporting for later words")
        // Exercise the actual two-segment HTTP path: preceding text must not
        // enter the next request, even after a short first sentence.
        let independent = try makePlayback(session, key: "synthetic-context")
        let first = "[chuckles] 好的。"
        let second = "这是另一段需要完整合成的文字。"
        try independent.appendText(first, final: false)
        try independent.appendText(second, final: true)
        do { try await independent.waitUntilFinished() } catch { /* Synthetic HTTP 400. */ }
        let requests = try EmptySpeechProtocol.contextRequests.all.map {
            try JSONSerialization.jsonObject(with: $0) as! [String: Any]
        }
        precondition(requests.count == 2, "each segment should produce one request")
        precondition(Set(requests.compactMap { $0["text"] as? String }) == Set([first, second]),
                     "both segment texts must be preserved exactly")
        precondition(requests.allSatisfy { $0["model_id"] as? String == "eleven_v4" && $0["previous_text"] == nil },
                     "synthesis must receive only this segment, without preceding text")
        print("PASS: non-speech input skips without reply failure; real words and other errors still fail; queue drains and logs retain the original error")
        print("PASS: short-first-sentence requests preserve both texts without previous_text")
    }

    @MainActor private static func makePlayback(_ session: URLSession, key: String = "synthetic-empty") throws -> SpeechPlayback {
        let playback = SpeechPlayback(session: session)
        try playback.begin(settings: .elevenLabs(ElevenLabsConfiguration(
            elevenLabsAPIKey: key, elevenLabsVoiceID: "synthetic-voice", elevenLabsModel: "eleven_v4")))
        return playback
    }
}
