import Foundation

/// Real HTTP/queue behavior with held synthetic PCM responses. The production
/// interruption switch pauses rendering throughout; no audio device is opened.
private final class StitchProtocol: URLProtocol, @unchecked Sendable {
    static let server = StitchServer()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let index = Self.server.add(self, body: body)
        let key = request.value(forHTTPHeaderField: "xi-api-key") ?? ""
        let text = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["text"] as? String
        let fails = key == "synthetic-failure" && text == "失败。"
        var headers = ["Content-Type": fails ? "application/json" : "audio/pcm"]
        if key != "synthetic-no-id" { headers["request-id"] = "synthetic-\(index)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: fails ? 400 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = fails ? Data(#"{"detail":{"status":"synthetic_failure"}}"#.utf8) : Data(repeating: 0, count: 4096)
        client?.urlProtocol(self, didLoad: data)
        Self.server.markReady(index)
        // Intentionally no EOF: the check controls when a response completes.
    }
    override func stopLoading() {}
    func complete() { client?.urlProtocolDidFinishLoading(self) }
}

private final class StitchServer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(StitchProtocol, Data)] = []
    private var ready: Set<Int> = []
    func add(_ connection: StitchProtocol, body: Data) -> Int {
        lock.withLock { calls.append((connection, body)); return calls.count - 1 }
    }
    func markReady(_ index: Int) { lock.withLock { _ = ready.insert(index) } }
    var count: Int { lock.withLock { calls.indices.prefix { ready.contains($0) }.count } }
    func body(_ index: Int) -> [String: Any] {
        let data = lock.withLock { calls[index].1 }
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func complete(_ index: Int) { lock.withLock { calls[index].0 }.complete() }
}

@main
struct SpeechStitchingChecks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StitchProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let server = StitchProtocol.server
        let playback = SpeechPlayback(session: session)
        playback.setAudioInterrupted(true)
        playback.retainsAudio = true
        var archived = 0
        playback.onAudioReady = { _, _ in archived += 1 }
        func begin(_ key: String = "synthetic-stitch", model: String = "eleven_v4") throws {
            try playback.begin(settings: .elevenLabs(ElevenLabsConfiguration(
                elevenLabsAPIKey: key, elevenLabsVoiceID: "synthetic-voice", elevenLabsModel: model)))
        }
        try begin()
        let texts = ["[chuckles] 好的。"] + (1...4).map { String(repeating: "字", count: 22) + "\($0)。" }
        for text in texts { try playback.appendText(text, final: false) }
        try playback.appendText("", final: true)
        try await eventually { server.count >= 1 }
        try await Task.sleep(for: .milliseconds(120))
        precondition(server.count == 1, "response headers and partial PCM must not release the next request")
        for index in texts.indices {
            try await eventually { server.count == index + 1 }
            let body = server.body(index)
            precondition(body["text"] as? String == texts[index], "keep original text and tags exactly")
            precondition(body["previous_text"] == nil)
            let expected = (max(0, index - 3)..<index).map { "synthetic-\($0)" }
            precondition((body["previous_request_ids"] as? [String] ?? []) == expected,
                         "only the last three fully received successful requests may be referenced")
            server.complete(index)
        }
        try await eventually { archived == 5 }
        precondition(!playback.isPlaying && playback.synthesisError == nil,
                     "later requests complete while rendering is paused, without waiting for playback")

        // A new turn starts clean even after a completed chain.
        try begin()
        try playback.appendText("新回复。", final: true)
        try await eventually { server.count == 6 }
        precondition(server.body(5)["previous_request_ids"] == nil)
        playback.stop() // Cancel before EOF: its header ID must never survive.
        try begin()
        try playback.appendText("取消后再回复。", final: true)
        try await eventually { server.count == 7 }
        precondition(server.body(6)["previous_request_ids"] == nil)
        let beforeCompletion = archived
        server.complete(6)
        try await eventually { archived == beforeCompletion + 1 }

        // An error response with a request ID must never become context.
        try begin("synthetic-failure")
        try playback.appendText("失败。", final: false)
        try playback.appendText(String(repeating: "后", count: 22) + "。", final: true)
        try await eventually { server.count == 8 }
        server.complete(7)
        try await eventually { server.count == 9 }
        precondition(server.body(8)["previous_request_ids"] == nil)
        let beforeRecovery = archived
        server.complete(8)
        try await eventually { archived == beforeRecovery + 1 }
        precondition(playback.synthesisError != nil, "keep the first failure diagnosable while the next segment succeeds")
        playback.stop()

        // A successful response without an ID still advances the queue.
        try begin("synthetic-no-id")
        try playback.appendText("无编号。", final: false)
        try playback.appendText(String(repeating: "后", count: 22) + "。", final: true)
        try await eventually { server.count == 10 }
        server.complete(9)
        try await eventually { server.count == 11 }
        precondition(server.body(10)["previous_request_ids"] == nil)
        playback.stop()

        // Known unsupported/unknown models preserve the independent path.
        for model in ["eleven_v3", "eleven_v3_conversational", "custom-model"] {
            let start = server.count
            try begin(model: model)
            try playback.appendText("第一句。", final: false)
            try playback.appendText(String(repeating: "后", count: 22) + "。", final: true)
            try await eventually { server.count == start + 2 }
            precondition(server.body(start + 1)["previous_request_ids"] == nil)
            playback.stop()
        }
        // If an earlier response stalls, begin one more request after 500 ms.
        // Complete responses out of order: only finished, source-ordered IDs
        // may be used, and two active requests remain the upper bound.
        let start = server.count
        try begin()
        try playback.appendText("首段。", final: false)
        for number in 1...3 {
            try playback.appendText(String(repeating: "续", count: 22) + "\(number)。", final: false)
        }
        try playback.appendText("", final: true)
        let beganAt = ProcessInfo.processInfo.systemUptime
        try await eventually { server.count == start + 2 }
        precondition(ProcessInfo.processInfo.systemUptime - beganAt >= 0.45, "allow a brief stitching wait before fallback")
        precondition(server.body(start + 1)["previous_request_ids"] == nil, "never reference a held response's header ID")
        try await Task.sleep(for: .milliseconds(100))
        precondition(server.count == start + 2, "at most two requests can be active")
        server.complete(start + 1)
        try await eventually { server.count == start + 3 }
        precondition(server.body(start + 2)["previous_request_ids"] as? [String] == ["synthetic-\(start + 1)"])
        server.complete(start)
        try await eventually { server.count == start + 4 }
        precondition(server.body(start + 3)["previous_request_ids"] as? [String] == ["synthetic-\(start)", "synthetic-\(start + 1)"],
                     "context stays in source order when HTTP completion order differs")
        let beforeTail = archived
        server.complete(start + 2)
        server.complete(start + 3)
        try await eventually { archived == beforeTail + 2 }
        playback.stop()

        let cancelledAt = server.count
        try begin()
        try playback.appendText("先说。", final: false)
        try playback.appendText(String(repeating: "后", count: 22) + "。", final: true)
        try await eventually { server.count == cancelledAt + 1 }
        playback.stop()
        try await Task.sleep(for: .milliseconds(550))
        precondition(server.count == cancelledAt + 1, "cancelling a turn also cancels the stitching wait")
        print("PASS: full-response context, last-three IDs, preserved text/tags, receive without playback, failed-segment recovery, cancellation, unsupported models, 500ms fallback, two-request cap and out-of-order completion")
    }

    @MainActor private static func eventually(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("synthetic request queue did not reach the expected state", file: file, line: line)
    }
}
