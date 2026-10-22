// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import Observation

@MainActor @Observable
final class CallTextInputRequest {
    static let shared = CallTextInputRequest()
    var startedAt: Date?
    var previewStartedAt: Date?
    var previewRequestedAt: Date?
}

/// Text controls share their lifetime with CallScreen, including while voice presentation is visible.
struct CallTextComposer: View {
    @MainActor @Observable
    final class State {
        fileprivate var composeFocusRequested = false
        fileprivate var isComposerExpanded = false
        fileprivate var isAttachmentPickerActive = false
        fileprivate var attachedImages: [CallDraftImage] = []
        fileprivate var isLoadingImages = false
        fileprivate var attachmentNotice: String?

        func requestFocus() { composeFocusRequested = true }
        func resetExpansion() { isComposerExpanded = false }
        func focusChanged(_ focused: Bool) { if focused { isComposerExpanded = true } }

        /// Picker dismissal owns focus restoration; transcript taps must not interrupt it.
        func collapse() -> Bool {
            guard !isAttachmentPickerActive else { return false }
            composeFocusRequested = false
            isComposerExpanded = false
            return true
        }
    }

    @Bindable var state: State
    @Binding var draft: String
    @FocusState.Binding var inputFocused: Bool
    let isCallActive: Bool
    let isConfigured: Bool
    let canSend: Bool
    let microphoneAvailable: Bool
    let isMuted: Bool
    let isPreview: Bool
    let textScale: Double
    let onSend: (String) -> Bool
    let onSendImages: ((String, [Data]) -> Bool)?
    let onToggleMute: () -> Void
    let onHangUp: () -> Void
    let onPickerDismiss: () -> Void
    @Environment(\.callPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptionFontStore.selectionKey) private var captionFontName = ""
    @SwiftUI.State private var captionFonts = CaptionFontStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = state.attachmentNotice {
                Text(notice).font(CallNight.font(11)).foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .task(id: notice) {
                        do { try await Task.sleep(for: .seconds(3)) }
                        catch { return }
                        state.attachmentNotice = nil
                    }
            }
            if !state.attachedImages.isEmpty {
                CallDraftImageStrip(images: $state.attachedImages).padding(.leading, 52)
            }
            if state.isLoadingImages { ProgressView().frame(maxWidth: .infinity).accessibilityLabel("正在准备图片") }
            HStack(alignment: .bottom, spacing: 8) {
                CallAttachmentButton(images: $state.attachedImages, isLoading: $state.isLoadingImages,
                                     isPickerActive: $state.isAttachmentPickerActive,
                                     isExpanded: showsAttachmentMenu, onHangUp: {
                    guard !showsAttachmentMenu else { return }
                    onHangUp()
                }, onPickerDismiss: onPickerDismiss) {
                        state.attachmentNotice = $0
                }
                .disabled(showsAttachmentMenu && (!canSend || state.isLoadingImages))
                composer
            }
        }
        .foregroundStyle(palette.primaryText)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var composer: some View {
        HStack(spacing: 0) {
            TextField("", text: $draft, prompt: Text(inputFocused ? String(localized: "输入时暂停收音") : String(localized: "打字说…")).foregroundStyle(palette.secondaryText), axis: .vertical)
                .font(Font(captionFonts.font(named: captionFontName, size: 15 * textScale)))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1...4).focused($inputFocused).padding(.vertical, 12).padding(.leading, 16)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    guard canSend else { return }
                    inputFocused = true
                })
                .accessibilityLabel("通话文字输入")
                .disabled(!canSend)
                .task(id: state.composeFocusRequested && canSend) {
                    guard state.composeFocusRequested, canSend else { return }
                    await Task.yield()
                    guard !Task.isCancelled, isCallActive else { return }
                    inputFocused = true
                    state.composeFocusRequested = false
                }
            Button {
                if hasDraft { submit() }
                else if inputFocused {
                    if state.collapse() { inputFocused = false }
                } else { onToggleMute() }
            } label: {
                ZStack {
                    Image(systemName: isMuted || inputFocused ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 19, weight: .medium))
                        .scaleEffect(hasDraft && !reduceMotion ? 0.35 : 1)
                        .opacity(hasDraft ? 0 : 1)
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                        .scaleEffect(!hasDraft && !reduceMotion ? 0.35 : 1)
                        .opacity(hasDraft ? 1 : 0)
                }
                .frame(width: 36, height: 36)
                .glassEffect(hasDraft && canSubmit ? .regular.interactive() : .identity, in: Circle())
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.8), value: hasDraft)
            }
            .disabled(hasDraft ? !canSubmit : !microphoneAvailable)
            .accessibilityLabel(hasDraft ? String(localized: "发送通话文字") : (inputFocused ? String(localized: "退出文字输入") : (isMuted ? String(localized: "开启麦克风") : String(localized: "关闭麦克风"))))
            .accessibilityValue(inputFocused ? String(localized: "输入期间已暂停收音") : (hasDraft ? "" : (microphoneAvailable ? (isMuted ? String(localized: "已关闭") : String(localized: "已打开")) : String(localized: "麦克风不可用"))))
            .accessibilityHint(inputFocused && !hasDraft ? String(localized: "退出输入后恢复原来的麦克风状态") : "")
        }
        .buttonStyle(.plain)
        .modifier(CallGlass(cornerRadius: 24))
    }

    private var showsAttachmentMenu: Bool {
        state.isComposerExpanded || inputFocused || state.composeFocusRequested || !draft.isEmpty || !state.attachedImages.isEmpty || state.isAttachmentPickerActive || state.isLoadingImages
    }

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.attachedImages.isEmpty }

    private var canSubmit: Bool { isCallActive && isConfigured && canSend && hasDraft && !state.isLoadingImages }

    private func submit() {
        guard canSubmit else { return }
        if isPreview, !state.attachedImages.isEmpty {
            state.attachmentNotice = String(localized: "预览不会发送图片")
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = state.attachedImages.isEmpty ? onSend(text) : (onSendImages?(text, state.attachedImages.map(\.jpeg)) ?? false)
        if accepted {
            draft = ""
            state.attachedImages = []
            state.isComposerExpanded = false
            inputFocused = false
        }
    }
}
