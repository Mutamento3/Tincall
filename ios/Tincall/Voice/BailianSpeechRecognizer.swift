// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct BailianConfiguration {
    let apiKey: String
    let model: String
}

@MainActor
final class BailianSpeechRecognizer: SpeechRecognizer {
    // Every connection owns its task, PCM timeline, transcript receiver and log.
    // A finishing task can never reset or consume the next task's state.
    private final class Session {
        let id = UUID().uuidString.lowercased()
        let socket: URLSessionWebSocketTask
        let stream: AsyncStream<Data>
        var input: AsyncStream<Data>.Continuation?
        var sender: Task<Void, Never>?
        var receiver: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var log: RequestLogSpan?
        var started = false
        var finishing = false
        var reusedPreconnection = false
        var sentAudioBytes = 0
        var audioByteOffset = 0
        var currentSentenceStart = 0
        var lastSpeechStart = 0
        var speechActive = false
        var hasUnfinishedSentence = false
        var hasConfirmedSentence = false
        var hasRecognizedText = false
        var audio = STTReplayBuffer(limitBytes: 16_000 * 2 * 600)

        init(socket: URLSessionWebSocketTask) {
            self.socket = socket
            let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(100))
            stream = pair.stream
            input = pair.continuation
        }
    }

    private let configuration: BailianConfiguration
    // Bailian should not open a recognition task for a short cough/noise burst.
    // The capture gate keeps the onset PCM and only releases it after sustained
    // speech, so the first syllable is still sent once the gate opens.
    private let capture = MicrophoneCapture(requiresSustainedSpeech: true)
    var onSpeechActivityChange: ((Bool) -> Void)? {
        get { capture.onSpeechActivityChange }
        set { capture.onSpeechActivityChange = newValue }
    }
    private let logContext: () -> RequestLogContext?
    private let connectionName: String?
    private var active: Session?
    private var prepared: Session?
    private var draining: [String: Session] = [:]
    private var running = false
    private var paused = false
    private var recordingFinished = false
    private var callback: ((String, Bool, Data?) async -> Void)?
    private var onError: ((Error) async -> Void)?
    private var onReset: (() -> Void)?

    init(configuration: BailianConfiguration, logContext: @escaping () -> RequestLogContext? = { nil }, connectionName: String? = nil) {
        self.logContext = logContext
        self.connectionName = connectionName
        self.configuration = configuration
    }

    var currentInputAudio: Data {
        guard let active else { return Data() }
        return Data(active.audio.audio.dropFirst(max(0, active.currentSentenceStart - active.audioByteOffset)))
    }

    func start(callback: @escaping (String, Bool, Data?) async -> Void,
               onError: @escaping (Error) async -> Void, onReset: @escaping () -> Void) async throws {
        stop()
        self.callback = callback; self.onError = onError; self.onReset = onReset
        running = true
        onReset()
        try await capture.start(onAudio: { [weak self] value in await self?.accept(value) },
                          onError: { [weak self] error in await self?.fail(error) })
        prepareNextSession()
    }

    func setTranscriptionPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        capture.setPaused(paused)
        resetUtterance()
        onReset?()
        if !paused { prepareNextSession() }
    }

    func stopAndWait() async {
        stop()
        await capture.waitForStop()
    }

    func stop() {
        running = false; paused = false; recordingFinished = false
        capture.stop(); resetUtterance()
        callback = nil; onError = nil; onReset = nil
    }

    func finishRecording() throws -> Bool {
        capture.stop()
        recordingFinished = true
        if let prepared { close(prepared) }
        guard let active else { return !draining.isEmpty }
        active.finishing = true
        active.input?.finish(); active.input = nil
        armTimeout(active)
        return true
    }

    private func owns(_ session: Session) -> Bool {
        active === session || prepared === session || draining[session.id] === session
    }

    private func close(_ session: Session) {
        if active === session { active = nil }
        if prepared === session { prepared = nil }
        draining.removeValue(forKey: session.id)
        session.log?.response(session.socket.response)
        session.log?.finish(); session.log = nil
        session.input?.finish(); session.input = nil
        session.sender?.cancel(); session.sender = nil
        session.receiver?.cancel(); session.receiver = nil
        session.timeout?.cancel(); session.timeout = nil
        session.socket.cancel(with: .normalClosure, reason: nil)
    }

    private func resetUtterance() {
        if let active { close(active) }
        if let prepared { close(prepared) }
        for session in Array(draining.values) { close(session) }
        capture.reset()
    }

    private func makeSession() -> Session {
        var request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return Session(socket: URLSession.shared.webSocketTask(with: request))
    }

    private func prepareNextSession() {
        guard running, !paused, !recordingFinished, prepared == nil else { return }
        let session = makeSession()
        prepared = session
        connect(session)
    }

    private func beginUtterance() -> Session {
        // Reuse a connecting or task-started preconnection only while its socket
        // is live. Known idle failures are discarded; otherwise speech creates a
        // fresh socket. A close racing this check gets one zero-upload retry.
        if let prepared, prepared.socket.state != .running || prepared.socket.closeCode != .invalid || prepared.socket.error != nil {
            close(prepared)
        }
        let session: Session
        if let ready = prepared {
            prepared = nil
            session = ready
            session.reusedPreconnection = true
            active = session
        } else {
            session = makeSession()
            active = session
            connect(session)
        }
        onReset?()
        let log = RequestLogStore.shared.begin(service: .bailian, step: .transcription, context: logContext(),
                                              connectionName: connectionName, modelName: configuration.model)
        log.protect([configuration.apiKey])
        log.request(String(localized: "PCM16 · 16 kHz · 单声道 · 0.00 秒"))
        session.log = log
        armTimeout(session)
        return session
    }

    private func accept(_ value: (audio: Data, hasSpeech: Bool)) async {
        guard running, !paused, !recordingFinished else { return }
        do {
            if active == nil, !value.hasSpeech { return }
            let session = active ?? beginUtterance()
            session.speechActive = value.hasSpeech
            if value.hasSpeech {
                session.lastSpeechStart = session.audioByteOffset + session.audio.audio.count
                session.hasUnfinishedSentence = true
            }
            if !session.hasUnfinishedSentence, session.audio.audio.isEmpty {
                session.audioByteOffset += value.audio.count
                session.currentSentenceStart = session.audioByteOffset
            } else {
                try session.audio.append(value.audio)
            }
            session.log?.request(String(format: String(localized: "PCM16 · 16 kHz · 单声道 · %.2f 秒"), Double(session.audioByteOffset + session.audio.audio.count) / 32000), persistImmediately: false)
            if case .dropped = session.input?.yield(value.audio) {
                throw TincallError(message: String(localized: "百炼语音上传过慢，请重新打开麦克风"))
            }
            if value.hasSpeech, session.started { armTimeout(session) }
            finishIfIdle(session)
        } catch { await fail(error) }
    }

    private func finishIfIdle(_ session: Session) {
        guard active === session, session.hasConfirmedSentence, !session.hasUnfinishedSentence,
              !session.speechActive, !session.finishing else { return }
        // Detach immediately. New microphone PCM goes to the next connection,
        // even while this socket is still sending finish-task/awaiting completion.
        session.finishing = true
        active = nil
        draining[session.id] = session
        session.input?.finish(); session.input = nil
        armTimeout(session)
    }

    private func completeTask(_ session: Session) async {
        close(session)
        // A draining connection must never clear the next sentence's caption or
        // create a new input ID. Only an explicit microphone finish needs a final
        // empty completion when no recognition tasks remain.
        if recordingFinished, active == nil, draining.isEmpty {
            await callback?("", true, nil)
        }
    }

    private func connect(_ session: Session) {
        let socket = session.socket
        socket.resume()
        armTimeout(session)
        session.receiver = Task { [weak self] in
            guard let self else { return }
            var transcript = BailianTranscript()
            do {
                // run-task is safe to prepare without audio. No PCM (including
                // silent keepalive packets) is queued until actual speech onset.
                try await self.send([
                    "header": ["action": "run-task", "task_id": session.id, "streaming": "duplex"],
                    "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                                "model": self.configuration.model,
                                "parameters": ["format": "pcm", "sample_rate": 16000,
                                               "semantic_punctuation_enabled": false, "max_sentence_silence": 2000],
                                "input": [:]]
                ], on: socket)
                while !Task.isCancelled, self.owns(session) {
                    let message = try await socket.receive()
                    guard self.owns(session), !Task.isCancelled else { return }
                    session.log?.response(socket.response)
                    let data: Data
                    switch message {
                    case .string(let value): data = Data(value.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    guard data.count <= 1_048_576 else { throw TincallError(message: String(localized: "百炼识别响应过大")) }
                    let event: BailianTranscript.Event?
                    do { event = try transcript.consume(data, taskID: session.id) }
                    catch { session.log?.body(data); throw error }
                    guard let event else { continue }
                    switch event {
                    case .started:
                        guard !session.started else { continue }
                        session.started = true
                        session.timeout?.cancel(); session.timeout = nil
                        if self.active === session || session.finishing { self.armTimeout(session) }
                        session.sender = Task { [weak self] in
                            do {
                                for await pcm in session.stream {
                                    guard let self, self.owns(session), !Task.isCancelled else { return }
                                    try await socket.send(.data(pcm))
                                    guard self.owns(session), !Task.isCancelled else { return }
                                    session.sentAudioBytes += pcm.count
                                }
                                guard let self, self.owns(session), !Task.isCancelled else { return }
                                try await self.send(["header": ["action": "finish-task", "task_id": session.id, "streaming": "duplex"],
                                                     "payload": ["input": [:]]], on: socket)
                                guard self.owns(session), !Task.isCancelled else { return }
                                self.armTimeout(session)
                            } catch {
                                guard let self, self.owns(session), !Task.isCancelled else { return }
                                await self.sessionFailed(error, session: session)
                            }
                        }
                    case .transcript(let text, let final, let beginTime, let endTime):
                        // Finalized draining tasks cannot publish into the new input.
                        guard self.active === session else { continue }
                        session.hasRecognizedText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasRecognizedText
                        session.log?.text(transcript.text)
                        let audioEnd = session.audioByteOffset + session.audio.audio.count
                        let begin = min(beginTime, audioEnd / 32) * 32
                        session.currentSentenceStart = max(session.audioByteOffset, begin)
                        if !final { session.hasUnfinishedSentence = true }
                        var pcm: Data?
                        if final {
                            let end = endTime.flatMap { $0 >= beginTime ? min($0, audioEnd / 32) * 32 : nil } ?? audioEnd
                            let upper = max(session.currentSentenceStart, end)
                            pcm = session.audio.audio.subdata(in: (session.currentSentenceStart - session.audioByteOffset)..<(upper - session.audioByteOffset))
                            let remainder = session.audio.take(after: upper - session.audioByteOffset)
                            try session.audio.append(remainder)
                            session.audioByteOffset = upper
                            session.currentSentenceStart = upper
                            session.hasConfirmedSentence = endTime.map { $0 >= beginTime } ?? false
                            session.hasUnfinishedSentence = transcript.hasUnfinishedSentence || session.lastSpeechStart >= upper
                            session.log?.succeed(transcript.text)
                            session.log?.flush()
                        }
                        if final, !session.hasUnfinishedSentence, !session.finishing {
                            session.timeout?.cancel(); session.timeout = nil
                        } else { self.armTimeout(session) }
                        if final {
                            self.prepareNextSession()
                            self.finishIfIdle(session)
                        }
                        await self.callback?(text, final, pcm)
                        guard self.owns(session), !Task.isCancelled else { return }
                        if final, self.active == nil || self.active === session { self.onReset?() }
                    case .finished(let text):
                        if self.prepared === session { self.close(session); return }
                        guard session.finishing else { throw TincallError(message: String(localized: "百炼识别在输入结束前中止")) }
                        session.log?.succeed(text)
                        await self.completeTask(session)
                        return
                    case .responseTimeout(let error):
                        // VAD can open for a cough or other non-speech sound. If
                        // Bailian timed out without returning any characters,
                        // finish this recognition turn quietly and wait for the
                        // next onset instead of showing a network error.
                        if !session.hasRecognizedText {
                            if self.active === session { self.onReset?() }
                            session.log?.succeed()
                            await self.completeTask(session)
                            return
                        }
                        guard !session.hasUnfinishedSentence, !session.speechActive else { throw error }
                        session.log?.succeed(transcript.text)
                        await self.completeTask(session)
                        return
                    }
                }
            } catch {
                guard self.owns(session), !Task.isCancelled else { return }
                await self.sessionFailed(error, session: session)
            }
        }
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func armTimeout(_ session: Session) {
        session.timeout?.cancel()
        session.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.owns(session) else { return }
            if self.prepared === session {
                self.close(session)
            } else if self.draining[session.id] === session {
                session.log?.succeed()
                await self.completeTask(session)
            } else {
                if !session.hasRecognizedText {
                    if self.active === session { self.onReset?() }
                    session.log?.succeed()
                    await self.completeTask(session)
                } else {
                    await self.sessionFailed(TincallError(message: String(localized: "百炼语音识别响应超时"), requestCode: "timeout"), session: session)
                }
            }
        }
    }

    private func sessionFailed(_ error: Error, session: Session) async {
        guard owns(session) else { return }
        // Failed/idle-expired preparation has no recognition log and never calls
        // onError or auto-reconnects. The next speech falls back to a fresh task.
        if prepared === session { close(session); return }
        if draining[session.id] === session {
            if error is URLError { session.log?.succeed() }
            else { session.log?.fail(error) }
            await completeTask(session)
            return
        }
        if session.reusedPreconnection, session.sentAudioBytes == 0 {
            let replacement = makeSession()
            replacement.audio = session.audio
            replacement.audioByteOffset = session.audioByteOffset
            replacement.currentSentenceStart = session.currentSentenceStart
            replacement.lastSpeechStart = session.lastSpeechStart
            replacement.speechActive = session.speechActive
            replacement.hasUnfinishedSentence = session.hasUnfinishedSentence
            replacement.log = session.log; session.log = nil
            replacement.finishing = session.finishing
            close(session)
            active = replacement
            replacement.input?.yield(replacement.audio.audio)
            if replacement.finishing { replacement.input?.finish(); replacement.input = nil }
            connect(replacement)
            return
        }
        session.log?.response(session.socket.response)
        session.log?.fail(error)
        await fail(error)
    }

    private func fail(_ error: Error) async {
        guard running else { return }
        let handler = onError
        stop()
        await handler?(error)
    }
}
