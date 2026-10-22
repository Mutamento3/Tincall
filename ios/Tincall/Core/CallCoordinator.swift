import Foundation
import Observation

@MainActor
@Observable
final class CallCoordinator {
    var phase: CallPhase = .idle
    private(set) var endedByRemote = false
    var generation: GenerationState = .idle
    var playback: PlaybackState = .idle
    var partialTranscript = ""
    var floatingUserTranscript = ""
    var isUserSpeaking = false
    var isAwaitingSpeechTranscript = false
    var isMuted = false
    private(set) var isSpeakerEnabled = false
    private(set) var isTextInputActive = false
    var errorMessage: String?
    var revision = 0
    var record: CallRecord?
    var hasUnsavedAudio = false
    var savingCallIDs: Set<UUID> = []
    var externalConnectionLost = false
    var currentPlaybackCaption: String?
    private(set) var speechInterruptionEnabled = true
    private(set) var speechRecognitionConnectionID: UUID?
    private(set) var pendingSpeechRecognitionConnection: ConnectionProfile?
    private(set) var isSwitchingSpeechRecognition = false
    private(set) var speechRecognitionError: String?
    private(set) var originalAudioInputEnabled = false
    private(set) var pendingOriginalAudioInputEnabled: Bool?
    @ObservationIgnored private var textRecognitionConnection: ConnectionProfile?
    @ObservationIgnored private var pendingInputAudio: [UUID: Data] = [:]
    @ObservationIgnored private var speechRecognitionTask: Task<Void, Never>?
    var speechInterruptionAvailability: SpeechInterruptionAvailability = .unavailable

    @ObservationIgnored var onSaveRecord: ((CallRecord) throws -> Void)?
    @ObservationIgnored var onSaveAudio: ((UUID, VoiceAudioSegment) throws -> CallAudioAsset)?
    @ObservationIgnored var onSaveImages: ((UUID, UUID, [Data]) throws -> [CallImageAsset])?
    @ObservationIgnored var onLoadImages: ((UUID, CallMessage) throws -> [Data])?
    @ObservationIgnored var onDiscardImages: ((UUID, UUID, [CallImageAsset]) throws -> Void)?
    /// Persists a successfully selected in-call STT connection as the next-call default.
    @ObservationIgnored var onSpeechRecognitionUsed: ((UUID) throws -> Void)?
    @ObservationIgnored let model: ChatCompletionClient
    @ObservationIgnored let external: ExternalCallClient
    @ObservationIgnored let voice: any VoiceService
    @ObservationIgnored let summaryUserName: () -> String
    @ObservationIgnored private let transcriptCorrections: () -> [SpeechRecognitionCorrection]
    @ObservationIgnored var session: VoiceSessionID?
    @ObservationIgnored var sessions: [UUID: VoiceSessionID] = [:]
    @ObservationIgnored var records: [UUID: CallRecord] = [:]
    @ObservationIgnored var turns: [UUID: VoiceTurnID] = [:]
    @ObservationIgnored var modelEndTurn: VoiceTurnID?
    @ObservationIgnored var externalEndSession: VoiceSessionID?
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let summaryTasks: CallSummaryTasks
    @ObservationIgnored var pendingAudio: [UUID: [VoiceAudioSegment]] = [:]
    @ObservationIgnored var finalInputs: Set<UUID> = []
    @ObservationIgnored private(set) var pendingFinalInputs: [UUID: [CallMessage]] = [:]
    @ObservationIgnored var interruptedSpeechInputs: Set<UUID> = []
    @ObservationIgnored var partialInput: TranscriptResult?
    @ObservationIgnored var role: CallRole?
    @ObservationIgnored var connection: ConnectionProfile?
    @ObservationIgnored var ttsConnection: ConnectionProfile?
    @ObservationIgnored var historyRecords: [CallRecord] = []
    @ObservationIgnored var externalConnections: [UUID: ConnectionProfile] = [:]
    @ObservationIgnored var externalEventsTask: Task<Void, Never>?
    @ObservationIgnored var externalEventsError: String?
    @ObservationIgnored var externalControlTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var externalInputIDs: [UUID: UUID] = [:]
    @ObservationIgnored var externalReplyIDs: [UUID: UUID] = [:]
    @ObservationIgnored var audioSegmentOffsets: [UUID: Int] = [:]
    @ObservationIgnored var preparedIncoming: (session: VoiceSessionID, configuration: VoiceConfiguration, accepted: Bool)?
    struct IncomingOpening {
        let roleID: UUID
        let turn: VoiceTurnID
        var text = ""
        var status: MessageStatus = .generating
        var error: Error?
        var requestsEnd = false
        var attached = false
    }
    @ObservationIgnored var incomingOpening: IncomingOpening?
    @ObservationIgnored var textOnly = false
    @ObservationIgnored private var muteTransitionID: UUID?
    @ObservationIgnored private var speakerTransitionID: UUID?
    @ObservationIgnored private var speakerStateDuringTransition: Bool?
    @ObservationIgnored private var activityCheckpointTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointSession: VoiceSessionID?
    @ObservationIgnored private var checkpointStartedAt: Date?
    @ObservationIgnored private var checkpointBaseDuration: TimeInterval = 0

    init(voice: any VoiceService, model: ChatCompletionClient = ChatCompletionClient(), external: ExternalCallClient = ExternalCallClient(),
         transcriptCorrections: @escaping () -> [SpeechRecognitionCorrection] = { [] },
         summaryUserName: @escaping () -> String = { "" }) {
        self.voice = voice
        self.model = model
        self.summaryTasks = CallSummaryTasks(model: model)
        self.external = external
        self.transcriptCorrections = transcriptCorrections
        self.summaryUserName = summaryUserName
        voice.onEvent = { [weak self] event in self?.receive(event) }
    }

    var isCallActive: Bool { phase == .active || phase == .connecting }
    var connectedAt: Date? {
        guard phase != .connecting, let record, record.lastActiveAt != nil else { return nil }
        return record.startedAt
    }
    var canSend: Bool { phase == .active && session != nil && externalEndSession == nil }
    private var canBeginTurn: Bool {
        canSend && generation != .generating && playback != .playing && playback != .synthesizing &&
        record?.externalPendingInput == nil && record?.externalPendingControl == nil
    }
    var canInterrupt: Bool { generation == .generating || (isCallActive && (playback == .playing || playback == .synthesizing)) }
    var pendingInputCount: Int { record?.queuedInputIDs?.count ?? 0 }
    var supportsOriginalAudioInput: Bool {
        role?.effectiveCallMode == .standalone && (connection?.provider == .gemini || connection?.provider == .openAICompatible)
    }

    func configurationIssue(role: CallRole?, connections: [ConnectionProfile]) -> String? {
        do { _ = try validatedConnections(role: role, connections: connections); return nil }
        catch { return safeMessage(error) }
    }

    func requestPreview(role: CallRole, connections: [ConnectionProfile], historyRecords: [CallRecord], input: String) throws -> CallRequestPreview {
        guard let connection = connections.first(where: { $0.id == role.modelConnectionID }) else {
            throw TincallError(message: String(localized: "此联系人缺少模型连接"))
        }
        return try CallContextBuilder.requestPreview(role: role, connection: connection, historyRecords: historyRecords,
            input: input, currentMessages: isCallActive && self.role?.id == role.id ? record?.messages ?? [] : [],
            ttsConnection: connections.first { $0.id == role.ttsConnectionID },
            userName: summaryUserName(),
            loadImages: { [self] message in try loadImages(message, callID: record?.id) })
    }

    private func validatedSource(role: CallRole?, connections: [ConnectionProfile]) throws -> ConnectionProfile {
        guard let role else { throw TincallError(message: String(localized: "请选择通话联系人")) }
        let sourceID = role.effectiveCallMode == .standalone ? role.modelConnectionID : role.externalConnectionID
        guard let connection = connections.first(where: { $0.id == sourceID }) else {
            throw TincallError(message: role.effectiveCallMode == .standalone ? String(localized: "此联系人缺少模型连接") : String(localized: "此联系人缺少外部连接"))
        }
        if role.effectiveCallMode == .standalone { try model.validate(connection) }
        else { try external.validate(connection, role: role) }
        return connection
    }

    func validatedConnections(role: CallRole?, connections: [ConnectionProfile]) throws -> (ConnectionProfile, ConnectionProfile, ConnectionProfile) {
        let connection = try validatedSource(role: role, connections: connections)
        guard let role else { throw TincallError(message: String(localized: "请选择通话联系人")) }
        guard let stt = connections.first(where: { $0.id == role.sttConnectionID }), stt.provider.isSpeechRecognition else {
            throw TincallError(message: String(localized: "请选择 Apple、讯飞、百炼或 Whisper 兼容识别连接"))
        }
        if stt.provider == .whisperCompatible {
            guard let url = stt.endpoint, url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw TincallError(message: String(localized: "Whisper 兼容识别需要无内嵌凭据的 HTTPS 地址"))
            }
            guard !stt.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TincallError(message: String(localized: "请填写 Whisper 兼容识别的模型名称"))
            }
        } else {
            guard stt.endpoint == nil else { throw TincallError(message: String(localized: "此语音识别服务使用本机或固定供应商地址，请清除自定义地址")) }
        }
        let credentials = CredentialStore()
        if stt.provider == .xunfei {
            guard !stt.applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  try validVoiceSecret(credentials.read(connectionID: stt.id)),
                  try validVoiceSecret(credentials.read(connectionID: stt.id, field: .apiSecret)) else {
                throw TincallError(message: String(localized: "讯飞识别缺少 App ID、API Key 或 API Secret"))
            }
        } else if stt.provider == .bailian {
            guard stt.region == nil || stt.region == "beijing" else { throw TincallError(message: String(localized: "当前百炼 Paraformer 识别仅支持北京地域")) }
            guard stt.model.isEmpty || stt.model == "paraformer-realtime-v2" else { throw TincallError(message: String(localized: "当前百炼识别仅支持 paraformer-realtime-v2 模型")) }
            guard try validVoiceSecret(credentials.read(connectionID: stt.id)) else { throw TincallError(message: String(localized: "百炼识别缺少 API Key")) }
        }
        guard let tts = connections.first(where: { $0.id == role.ttsConnectionID }), tts.provider.isSpeechSynthesis else {
            throw TincallError(message: String(localized: "请选择 ElevenLabs、MiniMax 或 Fish Audio 语音连接"))
        }
        guard tts.endpoint == nil else { throw TincallError(message: String(localized: "语音合成使用固定供应商地址，请清除自定义地址")) }
        if tts.provider == .miniMax, let region = tts.region, region != "china" && region != "international" {
            throw TincallError(message: String(localized: "MiniMax 地域必须为中国或国际"))
        }
        let voiceOverride = role.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = voiceOverride.isEmpty ? tts.voiceID.trimmingCharacters(in: .whitespacesAndNewlines) : voiceOverride
        guard (tts.provider == .miniMax || !tts.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), !voiceID.isEmpty,
              try validVoiceSecret(credentials.read(connectionID: tts.id)) else {
            throw TincallError(message: String(localized: "语音连接缺少模型、音色或 API Key"))
        }
        return (connection, stt, tts)
    }

    func resolvedVoiceID(role: CallRole, tts: ConnectionProfile) -> String {
        let override = role.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? tts.voiceID.trimmingCharacters(in: .whitespacesAndNewlines) : override
    }

    private func validVoiceSecret(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && !value.contains("\r") && !value.contains("\n") && !value.contains("•") && !value.contains("*") && value != "已配置"
    }

    func start(role: CallRole, connections: [ConnectionProfile], retention: AudioRetention, historyRecords: [CallRecord] = [], textOnly: Bool = false) async {
        guard !isCallActive else { return }
        do { try await CallAccessStore.shared.requireAccess() }
        catch {
            errorMessage = safeMessage(error)
            CallAccessStore.shared.showsUnlock = true
            return
        }
        guard !isCallActive else { return }
        if let opening = incomingOpening { cancelIncomingOpening(callID: opening.turn.session.callID) }
        errorMessage = nil
        // Do not render the previous call while this new call is waiting for
        // access, connection validation, or the external service to answer.
        record = nil
        if !textOnly, let saved = (Array(records.values) + historyRecords)
            .filter({ canResumeExternal($0, role: role) })
            .max(by: { $0.startedAt < $1.startedAt }) {
            await resumeExternal(record: saved, role: role, connections: connections, retention: retention)
            // A remotely ended call is finalized above; only then may this dial start a new one.
            guard phase == .ended else { return }
        }
        do {
            let connection: ConnectionProfile
            let stt: ConnectionProfile?
            let tts: ConnectionProfile?
            if textOnly {
                connection = try validatedSource(role: role, connections: connections)
                stt = nil
                tts = nil
            } else {
                (connection, stt, tts) = try validatedConnections(role: role, connections: connections)
            }
            self.textOnly = textOnly
            let newRecord = CallRecord(roleID: role.id, roleName: role.displayName, callMode: role.effectiveCallMode,
                                       externalConnectionID: role.externalConnectionID,
                                       externalRoleID: role.effectiveCallMode == .standalone ? nil : role.externalRoleID)
            try save(newRecord)
            self.role = role
            self.connection = connection
            self.ttsConnection = tts
            resetSpeechRecognitionSelection(stt?.id)
            self.historyRecords = historyRecords.filter { $0.id != newRecord.id }
            record = newRecord
            records[newRecord.id] = newRecord
            if !textOnly, let summaryID = role.summaryConnectionID {
                summaryTasks.configure(callID: newRecord.id, role: role, connection: connections.first { $0.id == summaryID })
            }
            let newSession = VoiceSessionID(callID: newRecord.id, epoch: UUID())
            session = newSession
            sessions[newRecord.id] = newSession
            finalInputs.removeAll()
            interruptedSpeechInputs.removeAll()
            partialTranscript = ""
            floatingUserTranscript = ""
            isUserSpeaking = false
            isAwaitingSpeechTranscript = false
            partialInput = nil
            generation = .idle
            playback = .idle
            currentPlaybackCaption = nil
            speechInterruptionAvailability = .unavailable
            isMuted = false
            muteTransitionID = nil
            isSpeakerEnabled = false
            speakerTransitionID = nil
            phase = .connecting
            do {
                if role.effectiveCallMode != .standalone {
                    externalConnections[newRecord.id] = connection
                    mutate(newRecord.id) { $0.externalCallID = newRecord.id; $0.externalEpoch = 0; $0.externalEventCursor = 0 }
                    try save(records[newRecord.id] ?? newRecord)
                    let state = try await external.create(connection: connection, role: role, callID: newRecord.id,
                                                          expressionPrompt: tts?.effectiveExpressionPrompt ?? "", userName: summaryUserName())
                    mutate(newRecord.id) { $0.externalEpoch = state.epoch }
                    guard session == newSession, phase == .connecting else {
                        enqueueExternalControl(callID: newRecord.id, endsCall: true)
                        return
                    }
                    guard state.status == "active" else { throw TincallError(message: String(localized: "连接端未建立可用通话")) }
                    mutate(newRecord.id) { $0.externalCallID = state.id; $0.externalEpoch = state.epoch; $0.externalEventCursor = 0 }
                    try save(records[newRecord.id] ?? newRecord)
                }
                if let stt, let tts {
                    voice.setSpeechInterruptionEnabled(speechInterruptionEnabled)
                    try await voice.start(session: newSession, configuration: VoiceConfiguration(
                        stt: stt, tts: tts, voiceID: resolvedVoiceID(role: role, tts: tts), retention: retention))
                }
                guard session == newSession, phase == .connecting else { return }
                mutate(newRecord.id) { $0.startedAt = Date() }
                phase = .active
                startActivityCheckpoints(newSession)
                externalConnectionLost = false
                if role.effectiveCallMode != .standalone { startExternalEvents(session: newSession, connection: connection) }
            } catch {
                guard session == newSession else { return }
                stopActivityCheckpoints(newSession)
                if !textOnly { voice.stop() }
                phase = .failed
                isUserSpeaking = false
                isAwaitingSpeechTranscript = false
                session = nil
                mutate(newRecord.id) { $0.endedAt = Date(); $0.endedAbnormally = true }
                persist(newRecord.id)
                if role.effectiveCallMode != .standalone { enqueueExternalControl(callID: newRecord.id, endsCall: true) }
                throw error
            }
        } catch { errorMessage = safeMessage(error); if !isCallActive { phase = .failed } }
    }

    /// UI clears its draft only after this function actually accepts and saves input.
    @discardableResult
    func sendText(_ text: String, images: [Data] = []) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty || !images.isEmpty, let session else { return false }
        guard images.count <= 4 else { errorMessage = String(localized: "一次最多发送 4 张图片"); return false }
        var user = CallMessage(turnID: UUID(), role: .user, text: text)
        if !images.isEmpty {
            do {
                guard let onSaveImages else { throw TincallError(message: String(localized: "无法保存消息图片")) }
                user.images = try onSaveImages(session.callID, user.id, images)
            } catch { errorMessage = safeMessage(error); return false }
        }
        let interruptedTurn = canInterrupt ? turns[session.callID] : nil
        // Persist both the input and cancellation intent before stopping the old reply.
        guard accept(user, callID: session.callID, queued: true, interrupting: interruptedTurn) else {
            if let assets = user.images {
                do { try onDiscardImages?(session.callID, user.id, assets) }
                catch { errorMessage = safeMessage(error) }
            }
            return false
        }
        if interruptedTurn != nil { interrupt() }
        else { beginQueuedInput() }
        return true
    }

    func loadImages(_ message: CallMessage, callID: UUID?) throws -> [Data] {
        guard message.images?.isEmpty == false else { return [] }
        guard let callID, let onLoadImages else { throw TincallError(message: String(localized: "无法读取消息图片")) }
        return try onLoadImages(callID, message)
    }

    func requestSpeechRecognitionConnection(_ connection: ConnectionProfile) {
        guard phase == .active, !textOnly, !isSwitchingSpeechRecognition,
              !originalAudioInputEnabled, pendingOriginalAudioInputEnabled != true,
              connection.provider.isSpeechRecognition else { return }
        speechRecognitionError = nil
        pendingSpeechRecognitionConnection = connection.id == speechRecognitionConnectionID ? nil : connection
        applyPendingSpeechRecognitionConnection()
    }

    func requestOriginalAudioInput(_ enabled: Bool, connections: [ConnectionProfile]) {
        guard phase == .active, !textOnly, !isSwitchingSpeechRecognition else { return }
        speechRecognitionError = nil
        guard !enabled || supportsOriginalAudioInput else {
            speechRecognitionError = String(localized: "原声输入目前支持 Gemini 和 OpenAI 兼容模型直连，请确认模型及连接服务支持音频输入。")
            return
        }
        if enabled == originalAudioInputEnabled {
            pendingOriginalAudioInputEnabled = nil
            pendingSpeechRecognitionConnection = nil
            return
        }
        if enabled {
            guard let previous = connections.first(where: { $0.id == speechRecognitionConnectionID }) else { return }
            textRecognitionConnection = previous
            pendingSpeechRecognitionConnection = connections.first { $0.provider == .appleSpeech }
                ?? ConnectionProfile(name: String(localized: "Apple 本机识别"), provider: .appleSpeech, language: "zh-CN")
        } else {
            guard let previous = textRecognitionConnection else { return }
            pendingSpeechRecognitionConnection = previous
        }
        pendingOriginalAudioInputEnabled = enabled
        applyPendingSpeechRecognitionConnection()
    }

    private func applyPendingSpeechRecognitionConnection() {
        guard phase == .active, let identity = session, !textOnly,
              !isSwitchingSpeechRecognition, muteTransitionID == nil,
              !isUserSpeaking, partialTranscript.isEmpty, partialInput == nil,
              let connection = pendingSpeechRecognitionConnection else { return }
        let audioMode = pendingOriginalAudioInputEnabled
        isSwitchingSpeechRecognition = true
        speechRecognitionTask = Task { [weak self] in
            guard let self else { return }
            // A fresh utterance may have arrived before this task got actor time.
            guard self.session == identity else { return }
            defer {
                if self.session == identity {
                    self.isSwitchingSpeechRecognition = false
                    self.speechRecognitionTask = nil
                }
            }
            guard !self.isUserSpeaking, self.partialTranscript.isEmpty, self.partialInput == nil else { return }
            do {
                try await self.voice.setSpeechRecognitionConnection(connection)
                guard self.session == identity, !Task.isCancelled else { return }
                self.speechRecognitionConnectionID = connection.id
                if let audioMode {
                    self.originalAudioInputEnabled = audioMode
                } else {
                    do { try self.onSpeechRecognitionUsed?(connection.id) }
                    catch { self.speechRecognitionError = self.safeMessage(error) }
                }
            } catch {
                guard self.session == identity, !Task.isCancelled else { return }
                self.speechRecognitionError = self.safeMessage(error)
            }
            self.pendingSpeechRecognitionConnection = nil
            self.pendingOriginalAudioInputEnabled = nil
        }
    }

    func resetSpeechRecognitionSelection(_ id: UUID? = nil) {
        speechRecognitionTask?.cancel()
        speechRecognitionTask = nil
        speechRecognitionConnectionID = id
        pendingSpeechRecognitionConnection = nil
        isSwitchingSpeechRecognition = false
        speechRecognitionError = nil
        originalAudioInputEnabled = false
        pendingOriginalAudioInputEnabled = nil
        textRecognitionConnection = nil
        pendingInputAudio.removeAll()
    }

    func setSpeechInterruptionEnabled(_ enabled: Bool) {
        speechInterruptionEnabled = enabled
        voice.setSpeechInterruptionEnabled(enabled)
    }

    func setTextInputActive(_ active: Bool) {
        let active = active && phase == .active
        guard isTextInputActive != active else { return }
        isTextInputActive = active
        if active { isUserSpeaking = false; isAwaitingSpeechTranscript = false }
        // Temporary input suspension never changes the user's mute choice.
        voice.setTextInputActive(active)
        if active { partialTranscript = ""; partialInput = nil }
        applyPendingSpeechRecognitionConnection()
    }

    func toggleMute() async {
        guard phase == .active, let session, muteTransitionID == nil, !isSwitchingSpeechRecognition else { return }
        let transitionID = UUID()
        muteTransitionID = transitionID
        defer {
            if muteTransitionID == transitionID { muteTransitionID = nil }
            applyPendingSpeechRecognitionConnection()
        }
        let previous = isMuted
        let muted = !previous
        isMuted = muted
        if muted { isUserSpeaking = false; isAwaitingSpeechTranscript = false }
        // Present the tap before applying the input pause policy.
        await Task.yield()
        guard self.session == session, muteTransitionID == transitionID else { return }
        do {
            try await voice.setMicrophoneMuted(muted)
            guard self.session == session else { return }
            isMuted = muted
            if muted { partialTranscript = ""; partialInput = nil }
        } catch {
            if self.session == session, muteTransitionID == transitionID {
                isMuted = previous
                errorMessage = safeMessage(error)
            }
        }
    }

    func toggleSpeaker() async {
        guard phase == .active, let session, speakerTransitionID == nil else { return }
        let transitionID = UUID()
        speakerTransitionID = transitionID
        defer { if speakerTransitionID == transitionID { speakerTransitionID = nil } }
        let previous = isSpeakerEnabled
        let enabled = !previous
        speakerStateDuringTransition = nil
        isSpeakerEnabled = enabled
        await Task.yield()
        guard self.session == session, phase == .active else { return }
        do {
            try await voice.setSpeakerEnabled(enabled)
            guard self.session == session else { return }
            isSpeakerEnabled = speakerStateDuringTransition ?? enabled
        } catch {
            if self.session == session {
                isSpeakerEnabled = speakerStateDuringTransition ?? previous
                errorMessage = safeMessage(error)
            }
        }
    }

    func interrupt(automatically: Bool = false) {
        if let identity = externalEndSession, session == identity {
            externalEndSession = nil
            endFromExternal(identity)
            return
        }
        guard let id = record?.id, let turn = turns[id], canInterrupt else { return }
        if !automatically { CallAudioDiagnostics.record(.manualInterrupt, turn: turn.turnID) }
        cancelReply(turn, reason: .interrupt)
        if !textOnly { voice.interruptReply(turn) }
        playback = .idle
        currentPlaybackCaption = nil
        persist(id)
        enqueueExternalControl(callID: id, endsCall: false)
        if let identity = session, let connection = externalConnections[id] {
            // Cancel the outstanding wait; the new loop keeps listening for this call.
            startExternalEvents(session: identity, connection: connection)
        }
        beginQueuedInput()
    }

    func cancelReply(_ turn: VoiceTurnID, reason: MessageInterruption) {
        let id = turn.session.callID
        if modelEndTurn == turn { modelEndTurn = nil }
        // A completed reply can still be in the TTS synthesis queue. Stopping
        // that queue before its first playback callback is not an interrupted
        // audible reply, so keep the completed message clean.
        let shouldRecordInterruption = generation != .completed || playback == .playing
        // Invalidate before cancellation, so delayed deltas cannot affect this or a later turn.
        turns.removeValue(forKey: id)
        tasks.removeValue(forKey: id)?.cancel()
        mutate(id) { value in
            value.externalPendingInput = nil
            guard shouldRecordInterruption,
                  let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) else { return }
            value.messages[index].status = .interrupted
            value.messages[index].interruption = reason
        }
        if !shouldRecordInterruption {
            generation = .completed
        } else {
            generation = .interrupted
        }
        if session == turn.session { currentPlaybackCaption = nil }
    }

    func hangUp(abnormally: Bool = false, remotely: Bool = false) {
        guard isCallActive, let session else { return }
        incomingOpening = nil
        preparedIncoming = nil
        endedByRemote = remotely
        externalEndSession = nil
        modelEndTurn = nil
        stopActivityCheckpoints(session)
        RequestLogStore.shared.markHangUp(callID: session.callID)
        if canInterrupt, let turn = turns[session.callID] {
            cancelReply(turn, reason: .hangUp)
        } else {
            turns.removeValue(forKey: session.callID)
            tasks.removeValue(forKey: session.callID)?.cancel()
        }
        if let input = partialInput, !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !finalInputs.contains(input.inputID),
           pendingFinalInputs[session.callID]?.contains(where: { $0.id == input.inputID }) != true {
            let user = CallMessage(id: input.inputID, turnID: UUID(), role: .user,
                                   text: input.text, status: .interrupted, interruption: .hangUp)
            if !accept(user, callID: session.callID) {
                pendingFinalInputs[session.callID, default: []].append(user)
            }
        }
        self.session = nil
        resetSpeechRecognitionSelection()
        isTextInputActive = false
        externalEventsTask?.cancel()
        externalEventsTask = nil
        phase = .ended
        partialTranscript = ""
        floatingUserTranscript = ""
        isUserSpeaking = false
        isAwaitingSpeechTranscript = false
        partialInput = nil
        interruptedSpeechInputs.removeAll()
        if !textOnly { voice.stop() }
        playback = .idle
        currentPlaybackCaption = nil
        speechInterruptionAvailability = .unavailable
        mutate(session.callID) { $0.endedAt = Date(); $0.endedAbnormally = abnormally ? true : nil; $0.queuedInputIDs = nil }
        persist(session.callID)
        enqueueExternalControl(callID: session.callID, endsCall: true)
        // Summary is a separate task; the interrupted reply cannot continue.
        if summaryTasks.isConfigured(session.callID) {
            if pendingFinalInputs[session.callID]?.isEmpty == false {
                mutate(session.callID) { $0.summaryStatus = .pending }
                persist(session.callID)
            } else { requestSummary(callID: session.callID) }
        }
    }

    func retrySaving() {
        for id in Array(records.keys) {
            persist(id)
            while let user = pendingFinalInputs[id]?.first {
                guard accept(user, callID: id, queued: session?.callID == id && phase == .active) else { break }
                pendingFinalInputs[id]?.removeFirst()
                if pendingFinalInputs[id]?.isEmpty != false, pendingAudio[id]?.isEmpty != false { savingCallIDs.remove(id) }
                if session?.callID == id, phase == .active {
                    finalInputs.insert(user.id)
                    partialTranscript = ""
                }
            }
            persistAudio(id)
            if session?.callID == id, records[id]?.externalPendingInput != nil { sendExternalInput(callID: id) }
            if records[id]?.externalPendingControl != nil { sendExternalControl(callID: id) }
            if pendingFinalInputs[id]?.isEmpty != false, records[id]?.endedAt != nil,
               records[id]?.summaryStatus == .pending, summaryTasks.isConfigured(id) {
                requestSummary(callID: id)
            }
        }
        beginQueuedInput()
    }

    private func accept(_ user: CallMessage, callID: UUID, queued: Bool = false, interrupting turn: VoiceTurnID? = nil) -> Bool {
        guard var value = records[callID] else { return false }
        if modelEndTurn?.session.callID == callID { modelEndTurn = nil }
        if !value.messages.contains(where: { $0.id == user.id }) { value.messages.append(user) }
        if queued, value.queuedInputIDs?.contains(user.id) != true {
            value.queuedInputIDs = (value.queuedInputIDs ?? []) + [user.id]
        }
        if let turn {
            value.externalPendingInput = nil
            if let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) {
                value.messages[index].status = .interrupted
                value.messages[index].interruption = .interrupt
            }
            if externalConnections[callID] != nil, value.externalCallID != nil, value.externalPendingControl == nil {
                value.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: value.externalEpoch ?? 0, endsCall: false)
            }
        }
        do {
            try save(value)
            records[callID] = value
            publish(callID)
            persistAudio(callID)
            return true
        } catch { reportSavingFailure(error, callID: callID); return false }
    }

    private func beginTurn(_ user: CallMessage, session: VoiceSessionID) {
        guard let connection, let role, self.session == session, var value = records[session.callID] else { return }
        let assistant = CallMessage(turnID: user.turnID, role: .assistant, text: "", status: .generating)
        let turn = VoiceTurnID(session: session, turnID: user.turnID, messageID: assistant.id)
        value.messages.append(assistant)
        value.queuedInputIDs?.removeAll { $0 == user.id }
        if role.effectiveCallMode != .standalone {
            value.externalPendingInput = ExternalPendingInput(requestID: user.id, messageID: user.id,
                replyMessageID: assistant.id, epoch: value.externalEpoch ?? 0)
            value.externalReplyID = nil
        }
        do {
            try save(value)
        } catch {
            savingCallIDs.insert(session.callID)
            errorMessage = String(localized: "输入已保存，回复尚未开始，请重试保存：\(safeMessage(error))")
            return
        }
        records[session.callID] = value
        publish(session.callID)
        RequestLogStore.shared.registerTurn(callID: session.callID, inputID: user.id, turnID: user.turnID)
        turns[session.callID] = turn
        CallAudioDiagnostics.record(.turnBegan, turn: turn.turnID, input: user.id)
        errorMessage = nil
        generation = .generating
        playback = textOnly ? .idle : .synthesizing
        currentPlaybackCaption = nil
        if !textOnly {
            do { try voice.beginReply(turn) }
            catch { playback = .failed; errorMessage = safeMessage(error) }
        }
        let history = records[session.callID]?.messages.filter { $0.id != assistant.id && $0.createdAt <= user.createdAt } ?? []
        if role.effectiveCallMode != .standalone {
            externalInputIDs[session.callID] = user.id
            externalReplyIDs.removeValue(forKey: session.callID)
            sendExternalInput(callID: session.callID)
            return
        }
        let audio = pendingInputAudio.removeValue(forKey: user.id)
        let context: CallContext
        do { context = try CallContextBuilder.build(role: role, historyRecords: historyRecords, currentMessages: history, ttsConnection: ttsConnection,
            userName: summaryUserName(),
            loadImages: { [self] message in try loadImages(message, callID: session.callID) },
            assistantInitiated: value.externalCallID != nil,
            audioInput: audio.map { (messageID: user.id, audio: $0) }) }
        catch { complete(turn, status: .failed, error: error); return }
        tasks[session.callID] = Task { [weak self, model] in
            do {
                var timestampFilter = CallTimestampStreamFilter()
                var endFilter = CallEndStreamFilter()
                let timeAware = role.timeAwarenessEnabled == true
                _ = try await model.stream(connection: connection, messages: context.messages, logContext: RequestLogStore.shared.context(for: turn),
                                           omittedTurnCount: context.omittedTurnCount) { delta in
                    let cleaned = endFilter.append(delta)
                    let text = timeAware ? timestampFilter.append(cleaned) : cleaned
                    if !text.isEmpty { self?.receiveDelta(text, turn: turn) }
                }
                let endTail = endFilter.append("", final: true)
                let tail = timeAware ? timestampFilter.append(endTail, final: true) : endTail
                if !tail.isEmpty { self?.receiveDelta(tail, turn: turn) }
                if endFilter.requestsEnd, self?.turns[session.callID] == turn {
                    self?.modelEndTurn = turn
                }
                self?.complete(turn, status: .completed)
            } catch {
                if Task.isCancelled { return }
                self?.complete(turn, status: .failed, error: error)
            }
        }
    }

    func receiveDelta(_ delta: String, turn: VoiceTurnID) {
        guard turns[turn.session.callID] == turn else { return }
        mutate(turn.session.callID) { value in
            if let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) { value.messages[index].text += delta }
        }
        // A shortcut can outlive its dialog; keep every received delta durable before suspension.
        if textOnly { persist(turn.session.callID); return }
        guard session == turn.session, phase == .active, playback != .failed else { return }
        do { try voice.appendReply(delta, to: turn) }
        catch { playback = .failed; errorMessage = safeMessage(error); voice.interruptReply(turn) }
    }

    func complete(_ turn: VoiceTurnID, status: MessageStatus, error: Error? = nil) {
        let id = turn.session.callID
        guard turns[id] == turn else { return }
        CallAudioDiagnostics.record(.turnCompleted, turn: turn.turnID, flag: status == .completed)
        tasks.removeValue(forKey: id)
        mutate(id) { value in
            if let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) { value.messages[index].status = status }
        }
        persist(id)
        guard session == turn.session || (record?.id == id && phase == .ended) else { return }
        generation = status == .completed ? .completed : .failed
        if status != .completed, modelEndTurn == turn { modelEndTurn = nil }
        if let error { errorMessage = safeMessage(error) }
        if session == turn.session, !textOnly {
            if status == .completed, playback != .failed {
                do { try voice.finishReply(turn) }
                catch { playback = .failed; errorMessage = safeMessage(error); voice.interruptReply(turn) }
            } else {
                voice.interruptReply(turn)
                playback = .failed
            }
            if finishModelEndIfReady(turn) { return }
            beginQueuedInput()
        } else if textOnly {
            _ = finishModelEndIfReady(turn)
        }
    }

    @discardableResult
    private func finishModelEndIfReady(_ turn: VoiceTurnID) -> Bool {
        guard modelEndTurn == turn, turns[turn.session.callID] == turn, session == turn.session,
              generation == .completed, textOnly || playback == .drained else { return false }
        guard !isUserSpeaking, !isAwaitingSpeechTranscript, partialTranscript.isEmpty,
              pendingFinalInputs[turn.session.callID]?.isEmpty != false,
              records[turn.session.callID]?.queuedInputIDs?.isEmpty != false else {
            modelEndTurn = nil
            return false
        }
        hangUp(remotely: true)
        return true
    }

    private func receive(_ event: VoiceEvent) {
        defer { applyPendingSpeechRecognitionConnection() }
        switch event {
        case let .speechActivity(identity, speaking):
            guard session == identity else { return }
            isUserSpeaking = speaking && phase == .active && !isMuted && !isTextInputActive
            if isUserSpeaking { modelEndTurn = nil }
            if isUserSpeaking, partialTranscript.isEmpty { isAwaitingSpeechTranscript = true }
        case let .transcript(identity, result):
            guard session == identity, phase == .active, !isTextInputActive,
                  !finalInputs.contains(result.inputID),
                  pendingFinalInputs[identity.callID]?.contains(where: { $0.id == result.inputID }) != true else { return }
            let result = result.corrected(using: transcriptCorrections())
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || result.isFinal || !isUserSpeaking { isAwaitingSpeechTranscript = false }
            if !text.isEmpty {
                CallAudioDiagnostics.record(.transcriptReceived, turn: turns[identity.callID]?.turnID,
                                            input: result.inputID, count: text.count, flag: result.isFinal)
            }
            if !text.isEmpty { floatingUserTranscript = text }
            let shouldInterrupt = speechInterruptionEnabled && !isMuted && !text.isEmpty &&
                !interruptedSpeechInputs.contains(result.inputID) && canInterrupt
            if !result.isFinal {
                partialTranscript = result.text
                partialInput = text.isEmpty ? nil : result
                if shouldInterrupt {
                    CallAudioDiagnostics.record(.autoPartialInterrupt, turn: turns[identity.callID]?.turnID, input: result.inputID)
                    interruptedSpeechInputs.insert(result.inputID)
                    interrupt(automatically: true)
                }
                return
            }
            partialInput = nil
            guard !text.isEmpty else { partialTranscript = ""; return }
            // User audio and final transcription share one stable message ID.
            let user = CallMessage(id: result.inputID, turnID: UUID(), role: .user, text: text)
            if originalAudioInputEnabled {
                // Missing audio fails the model request explicitly; never silently substitute the transcript.
                pendingInputAudio[user.id] = result.audio ?? Data()
            }
            let interruptedTurn = shouldInterrupt ? turns[identity.callID] : nil
            guard accept(user, callID: identity.callID, queued: true, interrupting: interruptedTurn) else {
                pendingFinalInputs[identity.callID, default: []].append(user)
                partialTranscript = result.text
                return
            }
            finalInputs.insert(result.inputID)
            partialTranscript = ""
            if interruptedTurn != nil {
                CallAudioDiagnostics.record(.autoFinalInterrupt, turn: interruptedTurn?.turnID, input: result.inputID)
                interruptedSpeechInputs.insert(result.inputID)
                interrupt(automatically: true)
            } else { beginQueuedInput() }
        case let .microphoneState(identity, muted):
            guard session == identity else { return }
            isMuted = muted
            if muted { isUserSpeaking = false; isAwaitingSpeechTranscript = false }
            if muted { partialTranscript = ""; partialInput = nil }
        case let .speakerState(identity, enabled):
            guard session == identity else { return }
            if speakerTransitionID != nil { speakerStateDuringTransition = enabled }
            else { isSpeakerEnabled = enabled }
        case let .playback(turn, state):
            guard session == turn.session, turns[turn.session.callID] == turn, phase == .active else { return }
            playback = state
            if state == .failed, modelEndTurn == turn { modelEndTurn = nil }
            if state == .playing { floatingUserTranscript = "" }
            if (state == .drained || state == .failed), externalEndSession == turn.session {
                if state == .failed { errorMessage = String(localized: "播放失败") }
                endFromExternal(turn.session)
                return
            }
            if state == .drained || state == .failed {
                currentPlaybackCaption = nil
                if state == .drained, finishModelEndIfReady(turn) { return }
                beginQueuedInput()
            }
        case let .playbackCaption(turn, caption):
            guard session == turn.session, turns[turn.session.callID] == turn, phase == .active else { return }
            currentPlaybackCaption = caption
        case let .speechInterruptionAvailability(identity, availability):
            guard session == identity else { return }
            speechInterruptionAvailability = availability
        case let .audioReady(identity, asset):
            guard sessions[identity.callID] == identity, records[identity.callID] != nil else {
                errorMessage = String(localized: "收到无关联通话的录音，源文件已保留")
                return
            }
            if pendingAudio[identity.callID]?.contains(where: { $0.id == asset.id }) != true {
                let adjusted = VoiceAudioSegment(id: asset.id, messageID: asset.messageID,
                    segmentIndex: asset.segmentIndex + (audioSegmentOffsets[asset.messageID] ?? 0),
                    fileURL: asset.fileURL, duration: asset.duration)
                pendingAudio[identity.callID, default: []].append(adjusted)
            }
            persistAudio(identity.callID)
        case let .failure(identity, message):
            guard session == identity else { return }
            errorMessage = message
        }
    }

    func beginQueuedInput() {
        guard canBeginTurn, let session, let value = records[session.callID],
              let id = value.queuedInputIDs?.first,
              let user = value.messages.first(where: { $0.id == id && $0.role == .user }) else { return }
        beginTurn(user, session: session)
    }

    func withActivityCheckpoint(_ value: CallRecord) -> CallRecord {
        guard let checkpointSession, checkpointSession == session,
              checkpointSession.callID == value.id, isCallActive,
              let checkpointStartedAt else { return value }
        var updated = value
        let now = Date()
        updated.lastActiveAt = max(now, value.startedAt)
        updated.recordedActiveDuration = checkpointBaseDuration + max(0, now.timeIntervalSince(checkpointStartedAt))
        return updated
    }

    func startActivityCheckpoints(_ identity: VoiceSessionID) {
        activityCheckpointTask?.cancel()
        checkpointSession = identity
        checkpointBaseDuration = records[identity.callID]?.recordedDuration ?? 0
        checkpointStartedAt = Date()
        checkpointActivity(identity)
        activityCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard let self, self.session == identity, self.isCallActive else { return }
                self.checkpointActivity(identity)
            }
        }
    }

    private func checkpointActivity(_ identity: VoiceSessionID) {
        guard checkpointSession == identity, session == identity, isCallActive,
              let value = records[identity.callID] else { return }
        records[identity.callID] = withActivityCheckpoint(value)
        publish(identity.callID)
        persist(identity.callID)
    }

    func stopActivityCheckpoints(_ identity: VoiceSessionID) {
        guard checkpointSession == identity else { return }
        checkpointActivity(identity)
        activityCheckpointTask?.cancel()
        activityCheckpointTask = nil
        checkpointSession = nil
        checkpointStartedAt = nil
    }

    func safeMessage(_ error: Error) -> String {
        if let error = error as? TincallError { return error.message }
        if let error = error as? ExternalCallFailure { return error.localizedDescription }
        return String(localized: "操作失败（\((error as NSError).code)）")
    }
}
