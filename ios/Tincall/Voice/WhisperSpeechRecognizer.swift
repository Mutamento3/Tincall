import Foundation

@MainActor
final class WhisperSpeechRecognizer: SpeechRecognizer {
    private let configuration: WhisperConfiguration
    // Keep Whisper from opening a file upload for a short cough/noise burst;
    // confirmed onset PCM is replayed into the normal utterance buffer.
    private let capture = MicrophoneCapture(requiresSustainedSpeech: true)
    var onSpeechActivityChange: ((Bool) -> Void)? {
        get { capture.onSpeechActivityChange }
        set { capture.onSpeechActivityChange = newValue }
    }
    private let logContext: () -> RequestLogContext?
    private let connectionName: String?
    private let session: URLSession
    private var running = false
    private var paused = false
    private var capacityPaused = false
    private var generation = 0
    private var inputBuffer = WhisperInputBuffer()
    private var requestTask: Task<Void, Never>?
    private var callback: ((String, Bool, Data?) async -> Void)?
    private var onError: ((Error) async -> Void)?
    private var onReset: (() -> Void)?

    init(configuration: WhisperConfiguration, logContext: @escaping () -> RequestLogContext? = { nil }, connectionName: String? = nil) {
        self.logContext = logContext
        self.connectionName = connectionName
        self.configuration = configuration
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 60
        options.timeoutIntervalForResource = 90
        options.httpCookieStorage = nil
        options.urlCredentialStorage = nil
        session = URLSession(configuration: options, delegate: SpeechHTTPNoRedirects(), delegateQueue: nil)
    }

    var currentInputAudio: Data { inputBuffer.currentAudio }

    func start(callback: @escaping (String, Bool, Data?) async -> Void,
               onError: @escaping (Error) async -> Void, onReset: @escaping () -> Void) async throws {
        stop()
        self.callback = callback; self.onError = onError; self.onReset = onReset
        running = true
        onReset()
        try await capture.start(onAudio: { [weak self] value in await self?.accept(value) },
                          onError: { [weak self] error in await self?.fail(error) })
    }

    func setTranscriptionPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        capture.setPaused(paused)
        reset()
        onReset?()
    }

    func stopAndWait() async {
        stop()
        await capture.waitForStop()
    }

    func stop() {
        running = false; paused = false
        capture.stop(); reset()
        callback = nil; onError = nil; onReset = nil
    }

    func finishRecording() throws -> Bool {
        capture.stop()
        guard !inputBuffer.currentAudio.isEmpty else { return false }
        inputBuffer.finishRecording()
        pump()
        return true
    }

    private func reset() {
        generation += 1
        requestTask?.cancel(); requestTask = nil
        inputBuffer = WhisperInputBuffer()
        capacityPaused = false
        capture.setPaused(paused)
        capture.reset()
    }

    private func accept(_ value: (audio: Data, hasSpeech: Bool)) async {
        guard running, !paused, !capacityPaused else { return }
        do {
            try inputBuffer.append(value.audio, hasSpeech: value.hasSpeech)
            if inputBuffer.isFull {
                capacityPaused = true
                capture.setPaused(true)
            }
            pump()
        } catch { await fail(error) }
    }

    private func pump() {
        guard requestTask == nil, running, !paused, let pcm = inputBuffer.next() else { return }
        let expected = generation
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try self.configuration.request(pcm: pcm)
                let text = try await SpeechHTTP.perform(service: .whisper, step: .transcription, context: self.logContext(),
                                                       connectionName: self.connectionName, modelName: self.configuration.model) { log in
                    log.protect(request)
                    log.request(String(format: String(localized: "WAV · PCM16 · 16 kHz · 单声道 · %.2f 秒"), Double(pcm.count) / 32000))
                    let (bytes, response) = try await self.session.bytes(for: request)
                    log.response(response)
                    guard let response = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "Whisper 返回了无效响应")) }
                    guard (200..<300).contains(response.statusCode) else {
                        try await log.errorBody(bytes)
                        throw TincallError(message: String(localized: "Whisper 转写失败（HTTP \(response.statusCode)）"))
                    }
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard self.generation == expected else { throw CancellationError() }
                        guard data.count < WhisperTranscription.maximumResponseBytes else { throw TincallError(message: String(localized: "Whisper 转写响应过大")) }
                        data.append(byte)
                    }
                    try Task.checkCancellation()
                    guard self.generation == expected, self.running, !self.paused else { throw CancellationError() }
                    let text: String
                    do { text = try WhisperTranscription.text(from: data, statusCode: response.statusCode) }
                    catch { log.body(data); throw error }
                    log.text(text)
                    return text
                }
                self.requestTask = nil
                if let result = self.inputBuffer.complete(text: text) {
                    if !result.text.isEmpty { await self.callback?(result.text, true, result.pcm) }
                    // Core can start playback and pause/reset during the final callback.
                    guard self.generation == expected, self.running, !self.paused, !Task.isCancelled else { return }
                    self.capacityPaused = false
                    self.capture.setPaused(false)
                    self.onReset?()
                } else { self.pump() }
            } catch {
                guard self.generation == expected, !Task.isCancelled else { return }
                await self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) async {
        let handler = onError
        stop()
        await handler?(error)
    }
}
