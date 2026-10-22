// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

/// The caller renders Core messages in `content` and advances revision for actual text updates.
struct CallTranscriptView<Content: View>: View {
    let revision: Int
    let isEmpty: Bool
    let partialTranscript: String
    var awaitingSpeechTranscript = false
    var userDisplayName = String(localized: "我")
    var emptyPrompt = String(localized: "通话内容将在这里显示。")
    @ViewBuilder let content: () -> Content
    @Environment(\.callPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true
    @State private var scrollPhase = ScrollPhase.idle
    @State private var isFarFromBottom = false
    @State private var isReturnButtonHidden = false
    private let bottomID = "call-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Bottom anchoring needs the measured height of every multiline message.
                VStack(alignment: .leading, spacing: 0) {
                    if isEmpty, partialTranscript.isEmpty, !awaitingSpeechTranscript {
                        Text(emptyPrompt)
                            .font(CallNight.font(12))
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    content()
                    if !partialTranscript.isEmpty || awaitingSpeechTranscript {
                        CallLiveTranscriptRow(speaker: userDisplayName, text: partialTranscript, isOutgoing: true,
                                              isStreaming: true, timestamp: nil)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollPhaseChange { oldPhase, newPhase, context in
                if newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                    || oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating {
                    updateFollowing(with: context.geometry)
                }
                scrollPhase = newPhase
                if newPhase == .interacting || newPhase == .decelerating {
                    isReturnButtonHidden = false
                }
            }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                let distanceToBottom = new.contentSize.height + new.contentInsets.bottom
                    - new.contentOffset.y - new.containerSize.height
                isFarFromBottom = distanceToBottom > max(240, new.containerSize.height * 0.5)
                if scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating {
                    updateFollowing(with: new)
                }
                // Follow after layout too: revision can change before the new content has
                // its final height. Keyboard and text-size changes need the same treatment.
                if followsLatest, scrollPhase == .idle,
                   old.contentSize != new.contentSize || old.containerSize != new.containerSize
                    || old.contentInsets != new.contentInsets {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: revision) {
                if followsLatest, scrollPhase == .idle { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: partialTranscript) {
                if followsLatest, scrollPhase == .idle { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: awaitingSpeechTranscript) {
                if followsLatest, scrollPhase == .idle { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .task(id: scrollPhase) {
                guard scrollPhase == .idle, !followsLatest, !isReturnButtonHidden else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return // A new scroll phase or disappearance cancels this timer.
                }
                guard !Task.isCancelled, scrollPhase == .idle, !followsLatest else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    isReturnButtonHidden = true
                }
            }
            .overlay(alignment: .bottom) {
                if !followsLatest && isFarFromBottom && !isReturnButtonHidden {
                    Button {
                        followsLatest = true
                        withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 34, height: 34)
                            .modifier(CallControlSurface(tint: nil))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到最新消息")
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
    }

    private func updateFollowing(with geometry: ScrollGeometry) {
        let distanceToBottom = geometry.contentSize.height + geometry.contentInsets.bottom
            - geometry.contentOffset.y - geometry.containerSize.height
        // Button visibility has a wider threshold; following resumes only at the actual bottom.
        followsLatest = distanceToBottom <= 1
    }
}

struct CallLiveTranscriptRow: View {
    let speaker: String
    let text: String
    let isOutgoing: Bool
    let isStreaming: Bool
    let timestamp: Date?
    var onInterrupt: (() -> Void)? = nil
    var images: [CallImageAsset] = []
    var imageURL: ((CallImageAsset) throws -> URL)? = nil
    @Environment(\.callTextScale) private var textScale
    @Environment(\.callPalette) private var palette
    @AppStorage(CaptionFontStore.selectionKey) private var fontName = ""
    @State private var fonts = CaptionFontStore.shared

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 16) {
            HStack(spacing: 4) {
                Text(speaker)
                if isStreaming {
                    Text(isOutgoing ? String(localized: "· 正在听") : String(localized: "· 正在等待回复"))
                } else if let timestamp {
                    Text("·")
                    Text(timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .monospacedDigit()
                }
            }
            .font(CallNight.font(10 * textScale))
            .foregroundStyle(isOutgoing ? palette.userMetadata : palette.secondaryText)
            .padding(.trailing, onInterrupt == nil ? 0 : 56)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
            .overlay(alignment: .trailing) {
                if !isOutgoing, let onInterrupt {
                    Button(action: onInterrupt) {
                        Text("打断").font(CallNight.font(12, weight: .medium))
                            .foregroundStyle(palette.primaryText)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打断当前回复")
                    .offset(y: 6)
                }
            }
            if !images.isEmpty { CallMessageImages(images: images, imageURL: imageURL, isOutgoing: isOutgoing) }
            Group {
                if text.isEmpty && isStreaming { CallTranscriptDots() }
                else { Text(text) }
            }
                .font(Font(fonts.font(named: fontName, size: 16 * textScale, weight: .medium)))
                .foregroundStyle(palette.primaryText)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .shadow(color: isOutgoing && !palette.isLight ? .blue.opacity(0.34) : .clear, radius: 1.1, x: 1.5, y: 0.8)
                .opacity(isOutgoing && isStreaming ? 0.6 : 1)
                .textSelection(.enabled)
        }
        .padding(.leading, isOutgoing ? 48 : 0)
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.primaryText.opacity(0.09)).frame(height: 0.5)
                .accessibilityHidden(true)
        }
    }
}

struct CallTranscriptDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("...").hidden()
            .overlay(alignment: .leading) {
                TimelineView(.periodic(from: .now, by: 0.45)) { context in
                    Text(reduceMotion ? "..." : String(repeating: ".", count:
                        Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1))
                }
            }
            .accessibilityHidden(true)
    }
}

struct CallTranscriptRow: View {
    let speaker: String
    let text: String
    let isOutgoing: Bool
    let isStreaming: Bool
    var textFont: Font = .body
    var detailFont: Font = .caption
    var isRecordStyle = false
    var timestamp: Date? = nil
    var audioDuration: TimeInterval? = nil
    var playbackProgress = 0.0
    var isAudioPlaying = false
    var onToggleAudio: (() -> Void)? = nil
    var images: [CallImageAsset] = []
    var imageURL: ((CallImageAsset) throws -> URL)? = nil

    var body: some View {
        Group {
            if let onToggleAudio {
                row
                    .contentShape(RoundedRectangle(cornerRadius: isRecordStyle ? 0 : 8))
                    .onTapGesture(perform: onToggleAudio)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: isAudioPlaying ? String(localized: "暂停音频") : String(localized: "播放音频"), onToggleAudio)
            } else {
                row
            }
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(speaker)
                    .font(detailFont.weight(.semibold))
                    .lineLimit(isRecordStyle ? 1 : nil)
                if let timestamp {
                    Text(timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                        .font(detailFont.monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                }
                if isStreaming {
                    Text("生成中").font(detailFont)
                }
                if let audioDuration {
                    let remainingDuration = audioDuration * (1 - min(1, max(0, playbackProgress)))
                    Spacer(minLength: 8)
                    Image(systemName: isAudioPlaying ? "pause.fill" : "play.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(formattedDuration(remainingDuration))
                        .font(detailFont.monospacedDigit())
                        .accessibilityLabel("音频剩余时长 \(formattedDuration(remainingDuration))")
                }
            }
            .foregroundStyle(.secondary)
            if !images.isEmpty { CallMessageImages(images: images, imageURL: imageURL, isOutgoing: isOutgoing && !isRecordStyle) }
            Text(text.isEmpty && isStreaming ? String(localized: "等待回复文字…") : text)
                .font(textFont)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, isRecordStyle ? 0 : 16)
        .background {
            if !isRecordStyle {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        isOutgoing ? Color.accentColor.opacity(0.09) : Color(.secondarySystemGroupedBackground)
                        Color.accentColor.opacity(0.18)
                            .frame(width: geometry.size.width * min(1, max(0, playbackProgress)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .animation(isAudioPlaying ? .linear(duration: 0.1) : nil, value: playbackProgress)
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, duration)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
