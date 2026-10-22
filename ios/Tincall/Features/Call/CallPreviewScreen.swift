import SwiftUI

/// An explicit, local appearance preview. It never starts media, requests a reply, or saves a call.
struct CallPreviewScreen: View {
    let callActivity: CallActivityController
    let contactID: UUID?
    let name: String
    let avatarData: Data?
    let backgroundData: Data?
    var userAvatarData: Data? = nil
    var userDisplayName: String = String(localized: "我")

    private enum Scene: String, CaseIterable, Identifiable {
        case listening = "正在听"
        case hearing = "正在转写"
        case thinking = "正在等待回复"
        case speaking = "正在说话"
        case reconnecting = "连接中断"
        case ended = "通话结束"
        var id: Self { self }
    }

    private struct Line: Identifiable {
        let id = UUID()
        var text: String
        let isOutgoing: Bool
        let date: Date
    }

    @State private var scene: Scene = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TincallPreviewIdle") { return .listening }
        #endif
        return .speaking
    }()
    @State private var isMuted = false
    @State private var isSpeakerEnabled = false
    @State private var isTextInputActive = false
    @State private var speechInterruptionEnabled = true
    @State private var draft = ""
    @State private var previewID = UUID()
    @State private var startedAt = Date()
    @State private var endedAt: Date?
    @State private var lines: [Line] = []
    @State private var previewCaption = ""
    @State private var streamingLineID: UUID?

    private static var exampleReplies: [String] { [
        String(localized: "那我陪你坐一会儿。你不用急着找话题，也不用想着一定要说点有意思的事。看看水，吹吹风，听听路过的人在聊什么，等那阵急着赶路的感觉慢慢散掉。今天有没有哪一个很小的瞬间，让你觉得，啊，好像也没有那么糟？哪怕只是买到一杯刚好合口味的饮料，或者回家的时候，恰好看见了一片很好看的云。你想到什么，就慢慢告诉我，我就在这里听。"),
        String(localized: "我刚才一直在想，如果我也坐在你旁边，大概不会立刻开口说话。我会先顺着你看的方向望过去，看看那片金色的水面，看看远处的灯是一盏一盏亮起来的，还是你一回神，它们就已经把整条河照亮了。然后我可能会问你，冷不冷，要不要再坐五分钟。\n\n有时候，陪伴就是这样吧，不需要把安慰的话说得特别漂亮，只要你知道，沉默的时候，对面也没有离开。"),
        String(localized: "等你准备回家的时候，我们就慢慢往回走。你可以把手机放进口袋里，不用一直举着，也不用每一步都向我汇报。走到路口记得看车，经过便利店的时候，如果忽然想吃点什么，就进去挑一样。今天已经很努力了，不用连休息也安排得那么认真。\n\n到家以后，先把包放下，给自己倒一杯水。如果还想聊，我们就接着聊；如果觉得累了，那就去洗个热水澡，早点躺下来。没说完的话可以留到明天，我不会因为今晚少听了几句，就把你今天的心情忘掉。")
    ] }

    private var isActive: Bool { scene != .ended }
    private var canInterrupt: Bool { scene == .thinking || scene == .speaking }
    private var status: String {
        isMuted && scene == .listening ? String(localized: "麦克风已关闭") : String(localized: String.LocalizationValue(scene.rawValue))
    }
    private var activityState: TincallCallAttributes.ContentState {
        .init(status: status, startedAt: startedAt, isMuted: isMuted,
              microphoneAvailable: isActive && scene != .reconnecting, isSpeakerEnabled: isSpeakerEnabled,
              audioActivity: scene == .speaking ? .speaking : (scene == .listening && !isMuted ? .listening : .idle))
    }

    var body: some View {
        CallScreen(
            name: name,
            statusTitle: String(localized: "预览 · \(status)"),
            statusDetail: scene == .ended ? String(localized: "预览已结束") : "",
            isConfigured: true,
            isCallActive: isActive,
            canStart: true,
            canSend: isActive && scene != .reconnecting,
            microphoneAvailable: isActive && scene != .reconnecting,
            isMuted: isMuted,
            canInterrupt: canInterrupt,
            errorMessage: scene == .reconnecting ? String(localized: "连接已中断，通话文字已保留。") : nil,
            onRetrySaving: nil,
            onConfigure: nil,
            onStart: restart,
            onToggleMute: toggleMute,
            onTextInputActiveChange: { isTextInputActive = $0 && isActive },
            onInterrupt: { scene = .listening },
            onHangUp: { select(.ended) },
            onSend: { text in
                lines.append(Line(text: text, isOutgoing: true, date: .now))
                scene = .listening
                return true
            },
            isSpeakerEnabled: isSpeakerEnabled,
            onToggleSpeaker: { isSpeakerEnabled.toggle() },
            backgroundData: backgroundData,
            avatarData: avatarData,
            userAvatarData: userAvatarData,
            userDisplayName: userDisplayName,
            startedAt: startedAt,
            endedAt: endedAt,
            onReconnect: scene == .reconnecting ? { select(.listening) } : nil,
            textStatusTitle: scene == .thinking || scene == .reconnecting || scene == .ended ? status : nil,
            isPreview: true,
            assistantSpeaking: scene == .speaking,
            userSpeaking: scene == .hearing && !isMuted && !isTextInputActive,
            captionText: scene == .hearing ? String(localized: "嗯，我还想再和你聊一会儿……") : (scene == .speaking ? previewCaption : ""),
            captionSpeaker: scene == .hearing ? userDisplayName : name,
            speechInterruptionEnabled: speechInterruptionEnabled,
            speechInterruptionAvailability: isMuted || isTextInputActive ? .microphoneMuted : .beforePlaybackOnly,
            onSetSpeechInterruptionEnabled: { speechInterruptionEnabled = $0 },
            draft: $draft
        ) {
            CallTranscriptView(revision: lines.count + previewCaption.count + (scene == .thinking ? 1 : 0),
                               isEmpty: false,
                               partialTranscript: scene == .hearing && !isMuted && !isTextInputActive ? String(localized: "嗯，我还想再和你聊一会儿……") : "") {
                ForEach(lines) { line in
                    CallLiveTranscriptRow(speaker: line.isOutgoing ? userDisplayName : name,
                                          text: line.text, isOutgoing: line.isOutgoing,
                                          isStreaming: line.id == streamingLineID, timestamp: line.date,
                                          onInterrupt: !speechInterruptionEnabled && scene == .speaking && line.id == lines.last(where: { !$0.isOutgoing })?.id
                                              ? { scene = .listening } : nil)
                }
                if scene == .thinking {
                    CallLiveTranscriptRow(speaker: name, text: "", isOutgoing: false,
                                          isStreaming: true, timestamp: nil,
                                          onInterrupt: speechInterruptionEnabled ? nil : { scene = .listening })
                }
            }
        }
        .onAppear {
            if lines.isEmpty { loadExample() }
            if CallTextInputRequest.shared.previewStartedAt != startedAt {
                CallTextInputRequest.shared.previewRequestedAt = nil
                CallTextInputRequest.shared.previewStartedAt = startedAt
            }
            TincallTogglePreviewMicrophoneIntent.microphoneAction = { id in
                guard id == previewID, isActive else { return nil }
                toggleMute()
                return activityState
            }
            TincallTogglePreviewSpeakerIntent.speakerAction = { id in
                guard id == previewID, isActive else { return nil }
                isSpeakerEnabled.toggle()
                return activityState
            }
        }
        .onChange(of: startedAt) {
            CallTextInputRequest.shared.previewRequestedAt = nil
            CallTextInputRequest.shared.previewStartedAt = startedAt
        }
        .task(id: scene) {
            guard scene == .speaking else { previewCaption = ""; streamingLineID = nil; return }
            do {
                for text in Self.exampleReplies {
                    previewCaption = ""
                    let line = Line(text: "", isOutgoing: false, date: .now)
                    lines.append(line)
                    streamingLineID = line.id
                    for character in text {
                        try Task.checkCancellation()
                        previewCaption.append(character)
                        if let index = lines.firstIndex(where: { $0.id == line.id }) {
                            lines[index].text = previewCaption
                        }
                        try await Task.sleep(for: .milliseconds(45))
                    }
                    streamingLineID = nil
                    try await Task.sleep(for: .seconds(4))
                }
            } catch { return } // Leaving this preview state cancels the local caption demonstration.
        }
        .task(id: activityState) {
            guard !Task.isCancelled else { return }
            if isActive {
                await callActivity.updatePreview(id: previewID, contactID: contactID, name: name, state: activityState)
            } else {
                await callActivity.endPreview(id: previewID)
            }
        }
        .onDisappear {
            if CallTextInputRequest.shared.previewStartedAt == startedAt {
                CallTextInputRequest.shared.previewStartedAt = nil
                CallTextInputRequest.shared.previewRequestedAt = nil
            }
            TincallTogglePreviewMicrophoneIntent.microphoneAction = nil
            TincallTogglePreviewSpeakerIntent.speakerAction = nil
            let id = previewID
            Task { await callActivity.endPreview(id: id) }
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        if isMuted && scene == .hearing { scene = .listening }
    }

    private func select(_ value: Scene) {
        if value == .ended { endedAt = .now }
        else { endedAt = nil }
        if value == .hearing { isMuted = false }
        scene = value
    }

    private func restart() {
        startedAt = .now
        endedAt = nil
        isMuted = false
        isTextInputActive = false
        draft = ""
        scene = .speaking
        loadExample()
    }

    private func loadExample() {
        let exampleStartedAt = startedAt.addingTimeInterval(-136)
        lines = [
            Line(text: String(localized: "今天回来时，我绕到河边走了一会儿。"), isOutgoing: true,
                 date: exampleStartedAt.addingTimeInterval(12)),
            Line(text: String(localized: "这个时间的河边应该很舒服吧。你是慢慢走回来的，还是找了个地方坐一会儿？"), isOutgoing: false,
                 date: exampleStartedAt.addingTimeInterval(28)),
            Line(text: String(localized: "坐了一会儿。天还没完全黑，水面上有一点金色。突然就想给你打个电话。"), isOutgoing: true,
                 date: exampleStartedAt.addingTimeInterval(64))
        ]
    }
}
