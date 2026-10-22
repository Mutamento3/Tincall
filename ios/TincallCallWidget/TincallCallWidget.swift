import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct TincallCallWidget: Widget {
    private let soft = Color.white.opacity(0.6)
    private let faint = Color.white.opacity(0.14)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TincallCallAttributes.self) { context in
            HStack(spacing: 12) {
                avatar(context, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(context))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    statusLine(context.state, color: .white.opacity(0.78))
                }
                Spacer(minLength: 6)
                micButton(context, size: 38)
                speakerButton(context, size: 38)
            }
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .activityBackgroundTint(Color.clear)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(callURL(context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 10) {
                        avatar(context, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(context))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            statusLine(context.state, color: soft)
                                .fixedSize()
                        }
                    }
                    .frame(height: 56, alignment: .center)
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        micButton(context, size: 38)
                        speakerButton(context, size: 38)
                    }
                    .frame(height: 56, alignment: .center)
                    .padding(.trailing, 8)
                }
            } compactLeading: {
                avatar(context, size: 20)
            } compactTrailing: {
                compactIndicator(context.state)
            } minimal: {
                avatar(context, size: 20)
            }
            .widgetURL(callURL(context.attributes))
            .keylineTint(Color.white.opacity(0.3))
        }
    }

    private func displayName(_ context: ActivityViewContext<TincallCallAttributes>) -> String {
        context.state.displayName
            ?? context.attributes.avatarContactID.flatMap(TincallCallAvatar.displayName(for:))
            ?? context.attributes.name
    }

    private func avatar(_ context: ActivityViewContext<TincallCallAttributes>, size: CGFloat) -> some View {
        Group {
            if let contactID = context.state.avatarContactID ?? context.attributes.avatarContactID
                ?? TincallCallAvatar.incomingContactID(for: context.attributes.callID),
               let url = TincallCallAvatar.fileURL(for: contactID),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable().scaledToFit()
                    .padding(size * 0.24)
                    .foregroundStyle(soft)
                    .background(faint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
    }

    private func statusLine(_ state: TincallCallAttributes.ContentState, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(state.microphoneAvailable == false ? state.status : String(localized: "通话中"))
            if state.microphoneAvailable != false {
                Text("·")
                Text("00:00:00")
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(state.startedAt, style: .timer)
                            .monospacedDigit()
                            .multilineTextAlignment(.leading)
                            .minimumScaleFactor(0.8)
                    }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private func compactIndicator(_ state: TincallCallAttributes.ContentState) -> some View {
        CallCompactIndicator(state: state)
    }

    private func micButton(_ context: ActivityViewContext<TincallCallAttributes>, size: CGFloat) -> some View {
        let on = !context.state.isMuted
        let label = Image(systemName: on ? "mic.fill" : "mic.slash.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(on ? Color.primary : Color.black)
            .frame(width: size, height: size)
            .background(on ? Color.primary.opacity(0.08) : Color.white, in: Circle())
        return Group {
            if context.attributes.isPreview {
                Button(intent: TincallTogglePreviewMicrophoneIntent(callID: context.attributes.callID)) { label }
            } else {
                Button(intent: TincallToggleMicrophoneIntent(callID: context.attributes.callID)) { label }
                    .disabled(context.state.microphoneAvailable == false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? String(localized: "关掉麦克风") : String(localized: "打开麦克风"))
    }

    private func speakerButton(_ context: ActivityViewContext<TincallCallAttributes>, size: CGFloat) -> some View {
        let on = context.state.isSpeakerEnabled == true
        let label = Image(systemName: on ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(on ? Color.white : Color.primary.opacity(0.08), in: Circle())
        return Group {
            if context.attributes.isPreview {
                Button(intent: TincallTogglePreviewSpeakerIntent(callID: context.attributes.callID)) { label }
            } else {
                Button(intent: TincallToggleSpeakerIntent(callID: context.attributes.callID)) { label }
            }
        }
        .buttonStyle(.plain)
        .disabled(context.state.microphoneAvailable == false || context.state.isSpeakerEnabled == nil)
        .accessibilityLabel(on ? String(localized: "切换到听筒") : String(localized: "切换到扬声器"))
    }

    private func callURL(_ attributes: TincallCallAttributes) -> URL {
        URL(string: attributes.isPreview ? "tincall://call?preview=1" : "tincall://call")!
    }
}

private struct CallCompactIndicator: View {
    let state: TincallCallAttributes.ContentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var active: Bool {
        state.microphoneAvailable != false && (state.audioActivity == .speaking ||
            (state.audioActivity == .listening && !state.isMuted))
    }

    private var symbol: String {
        if state.microphoneAvailable == false { return "ellipsis" }
        if state.audioActivity == .speaking { return "speaker.wave.2.fill" }
        if state.audioActivity == .listening && !state.isMuted { return "waveform" }
        return state.isMuted ? "mic.slash.fill" : "mic.fill"
    }

    var body: some View {
        Image(systemName: symbol)
            .symbolEffect(.variableColor.iterative, options: .speed(1.5).repeat(2),
                          isActive: active && !reduceMotion && !isLuminanceReduced)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: state.isMuted && !active ? 11 : 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(state.microphoneAvailable == false || (state.isMuted && !active) ? 0.6 : 0.85))
            .frame(width: 20)
            .accessibilityLabel(state.status + (state.isMuted ? String(localized: "，麦克风已关闭") : ""))
    }
}
