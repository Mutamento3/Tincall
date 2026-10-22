// ActivityKit's Activity reference lacks Sendable annotations in this SDK.
// All application-owned activity state remains isolated to the main actor.
@preconcurrency import ActivityKit
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CallActivityController {
    private(set) var errorMessage: String?
    @ObservationIgnored
    private var activity: Activity<TincallCallAttributes>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var lastCallState: CallState?
    @ObservationIgnored private var pendingIncomingID: UUID?
    @ObservationIgnored private var pushStartTask: Task<Void, Never>?
    @ObservationIgnored private var activityObservationTask: Task<Void, Never>?
    @ObservationIgnored private var preparedAvatarCallID: UUID?
    @ObservationIgnored private var preparedAvatarContactID: UUID?
    @ObservationIgnored private var suppressedIncomingCallID: UUID?

    private struct CallState: Equatable {
        let callID: UUID?
        let startedAt: Date?
        let name: String?
        let contactID: UUID?
        let phase: CallPhase
        let generation: GenerationState
        let playback: PlaybackState
        let isMuted: Bool
        let isSpeakerEnabled: Bool
        let isUserSpeaking: Bool

        var status: String { CallActivityController.statusTitle(phase: phase, generation: generation,
                                                                playback: playback, isMuted: isMuted,
                                                                isUserSpeaking: isUserSpeaking) }

        var audioActivity: TincallCallAttributes.AudioActivity {
            guard phase == .active else { return .idle }
            if playback == .playing { return .speaking }
            return isUserSpeaking && !isMuted ? .listening : .idle
        }
    }

    static func statusTitle(_ coordinator: CallCoordinator) -> String {
        statusTitle(phase: coordinator.phase, generation: coordinator.generation,
                    playback: coordinator.playback, isMuted: coordinator.isMuted,
                    isUserSpeaking: coordinator.isUserSpeaking)
    }

    nonisolated private static func statusTitle(phase: CallPhase, generation: GenerationState,
                                    playback: PlaybackState, isMuted: Bool, isUserSpeaking: Bool) -> String {
        switch phase {
            case .idle: return String(localized: "准备通话")
            case .connecting: return String(localized: "正在连接")
            case .ended: return String(localized: "通话已结束")
            case .failed: return String(localized: "通话未能开始")
            case .active:
                if playback == .playing { return String(localized: "正在说话") }
                if playback == .failed { return String(localized: "播放失败") }
                if generation == .generating || playback == .synthesizing { return String(localized: "正在等待回复") }
                if isMuted { return String(localized: "麦克风已关闭") }
                return isUserSpeaking ? String(localized: "正在聆听") : String(localized: "通话中")
        }
    }

    init() {
        TincallMicrophoneDiagnostics.record(.handlerRegistered)
        TincallToggleMicrophoneIntent.microphoneAction = { callID in
            TincallMicrophoneDiagnostics.record(.handlerEntered)
            guard let coordinator = TincallRuntime.shared.coordinator else {
                TincallMicrophoneDiagnostics.record(.missingCoordinator)
                throw NSError(domain: "TincallCall", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "当前通话不可用，请打开 Tincall 查看")])
            }
            guard coordinator.isCallActive, coordinator.phase == .active else {
                TincallMicrophoneDiagnostics.record(.inactiveCall)
                throw NSError(domain: "TincallCall", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "当前通话不可用，请打开 Tincall 查看")])
            }
            guard coordinator.record?.id == callID else {
                TincallMicrophoneDiagnostics.record(.staleCall)
                throw NSError(domain: "TincallCall", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "当前通话不可用，请打开 Tincall 查看")])
            }
            let wasMuted = coordinator.isMuted
            TincallMicrophoneDiagnostics.record(.muteRequested)
            await coordinator.toggleMute()
            await TincallRuntime.shared.callActivity.refresh(coordinator)
            guard coordinator.isCallActive, coordinator.record?.id == callID,
                  coordinator.isMuted != wasMuted else {
                TincallMicrophoneDiagnostics.record(.muteUnchanged)
                throw NSError(domain: "TincallCall", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "麦克风未能切换，请打开 Tincall 查看通话状态")])
            }
            TincallMicrophoneDiagnostics.record(.muteChanged)
        }
        TincallToggleSpeakerIntent.speakerAction = { callID in
            guard let coordinator = TincallRuntime.shared.coordinator,
                  coordinator.isCallActive, coordinator.phase == .active,
                  coordinator.record?.id == callID else {
                throw NSError(domain: "TincallCall", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "当前通话不可用，请打开 Tincall 查看")])
            }
            let wasEnabled = coordinator.isSpeakerEnabled
            await coordinator.toggleSpeaker()
            await TincallRuntime.shared.callActivity.refresh(coordinator)
            guard coordinator.isCallActive, coordinator.record?.id == callID,
                  coordinator.isSpeakerEnabled != wasEnabled else {
                throw NSError(domain: "TincallCall", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "扬声器未能切换，请打开 Tincall 查看通话状态")])
            }
        }
    }

    /// Runtime-owned observation survives full-screen presentation and locking the phone.
    func startObserving(_ coordinator: CallCoordinator) {
        let record = withObservationTracking {
            _ = coordinator.phase
            _ = coordinator.generation
            _ = coordinator.playback
            _ = coordinator.isMuted
            _ = coordinator.isSpeakerEnabled
            _ = coordinator.isUserSpeaking
            return coordinator.record
        } onChange: { [weak self, weak coordinator] in
            Task { @MainActor in
                guard let coordinator else { return }
                self?.startObserving(coordinator)
            }
        }
        scheduleUpdate(record: record, coordinator: coordinator)
    }

    func refresh(_ coordinator: CallCoordinator) async {
        lastCallState = nil
        scheduleUpdate(record: coordinator.record, coordinator: coordinator)
        await updateTask?.value
    }

    /// Suppress the card while CallKit rings and hands off. The runtime clears
    /// suppression after system release, restoring the connected-call activity.
    func suppressIncoming(callID: UUID) {
        suppressedIncomingCallID = callID
        pendingIncomingID = nil
        guard activity?.attributes.callID == callID else { return }
        let current = activity
        activity = nil
        if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
    }

    func needsRemoteStart(callID: UUID) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        return !Activity<TincallCallAttributes>.activities.contains {
            $0.attributes.callID == callID && !$0.attributes.isPreview &&
            ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    func clearIncomingSuppression(callID: UUID) {
        if suppressedIncomingCallID == callID { suppressedIncomingCallID = nil }
    }

    func observePushStarts(onToken: @escaping (Data) -> Void) {
        guard pushStartTask == nil else { return }
        if let token = Activity<TincallCallAttributes>.pushToStartToken { onToken(token) }
        pushStartTask = Task {
            for await token in Activity<TincallCallAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                onToken(token)
            }
        }
        activityObservationTask = Task { [weak self] in
            for await incoming in Activity<TincallCallAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                await self?.adopt(incoming)
            }
        }
    }

    private func wantsActivity(for callID: UUID) -> Bool {
        pendingIncomingID == callID || (lastCallState?.callID == callID &&
            (lastCallState?.phase == .active || lastCallState?.phase == .connecting))
    }

    private func adopt(_ incoming: Activity<TincallCallAttributes>) async {
        guard !incoming.attributes.isPreview else { return }
        guard wantsActivity(for: incoming.attributes.callID) else {
            // Includes a start arriving after cancellation/hangup or process recovery.
            await incoming.end(nil, dismissalPolicy: .immediate)
            return
        }
        if let current = activity, current.id != incoming.id,
           current.attributes.callID == incoming.attributes.callID {
            await incoming.end(nil, dismissalPolicy: .immediate)
            return
        }
        activity = incoming
        errorMessage = nil
        if let state = lastCallState, state.callID == incoming.attributes.callID, let startedAt = state.startedAt {
            await incoming.update(ActivityContent(state: .init(status: state.status, startedAt: startedAt,
                isMuted: state.isMuted, microphoneAvailable: state.phase == .active,
                isSpeakerEnabled: state.isSpeakerEnabled, audioActivity: state.audioActivity,
                displayName: state.name, avatarContactID: callAvatar(callID: incoming.attributes.callID, contactID: state.contactID)), staleDate: nil))
        }
        CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_activity_adopted")
    }

    /// Prepare local identity while ringing, before a remote start can render.
    func startIncoming(callID: UUID, name: String, contactID: UUID?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let current = activity, current.attributes.callID == callID, !current.attributes.isPreview { return }

        pendingIncomingID = callID
        if let contactID { TincallCallAvatar.rememberName(name, for: contactID) }
        let avatarContactID = callAvatar(callID: callID, contactID: contactID)
        TincallCallAvatar.rememberIncoming(callID: callID, contactID: avatarContactID)

        if let delivered = Activity<TincallCallAttributes>.activities.first(where: { $0.attributes.callID == callID && !$0.attributes.isPreview }) {
            activity = delivered
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }

        let previous = activity
        activity = nil
        if let previous { Task { await previous.end(nil, dismissalPolicy: .immediate) } }
        let state = TincallCallAttributes.ContentState(status: String(localized: "正在连接"),
                                                        startedAt: Date(), isMuted: false,
                                                        microphoneAvailable: false,
                                                        isSpeakerEnabled: nil, audioActivity: .idle)
        do {
            activity = try Activity.request(
                attributes: TincallCallAttributes(callID: callID, name: name,
                                                   avatarContactID: avatarContactID),
                content: ActivityContent(state: state, staleDate: nil))
            errorMessage = nil
        } catch {
            activity = nil
            errorMessage = String(localized: "锁屏通话卡片未能显示，通话仍可继续。")
        }
    }

    func endIncoming(callID: UUID) {
        TincallCallAvatar.forgetIncoming(callID: callID)
        guard pendingIncomingID == callID || activity?.attributes.callID == callID else { return }
        if pendingIncomingID == callID { pendingIncomingID = nil }
        if activity?.attributes.callID == callID { activity = nil }
        Task {
            for current in Activity<TincallCallAttributes>.activities where current.attributes.callID == callID && !current.attributes.isPreview {
                await current.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func scheduleUpdate(record: CallRecord?, coordinator: CallCoordinator) {
        let state = CallState(callID: record?.id, startedAt: record?.startedAt, name: record?.roleName,
                              contactID: record?.roleID, phase: coordinator.phase,
                              generation: coordinator.generation, playback: coordinator.playback,
                              isMuted: coordinator.isMuted, isSpeakerEnabled: coordinator.isSpeakerEnabled,
                              isUserSpeaking: coordinator.isUserSpeaking)
        guard state != lastCallState else { return }
        if state.callID != lastCallState?.callID { errorMessage = nil }
        lastCallState = state
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            await self?.update(record: record, isActive: state.phase == .active || state.phase == .connecting,
                               status: state.status, isMuted: state.isMuted, isSpeakerEnabled: state.isSpeakerEnabled,
                               microphoneAvailable: state.phase == .active, audioActivity: state.audioActivity)
        }
    }

    func update(record: CallRecord?, isActive: Bool, status: String, isMuted: Bool, isSpeakerEnabled: Bool,
                microphoneAvailable: Bool, audioActivity: TincallCallAttributes.AudioActivity) async {
        guard !Task.isCancelled else { return }
        if let record, suppressedIncomingCallID == record.id, isActive {
            if activity?.attributes.callID == record.id {
                let current = activity
                activity = nil
                if let current { await current.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        if let record, suppressedIncomingCallID == record.id, !isActive {
            suppressedIncomingCallID = nil
        }
        if let record, pendingIncomingID == record.id { pendingIncomingID = nil }
        guard isActive, let record else {
            if pendingIncomingID != nil { return }
            if let record { TincallCallAvatar.forgetIncoming(callID: record.id) }
            let staleActivities = Activity<TincallCallAttributes>.activities.filter { !$0.attributes.isPreview }
            if activity?.attributes.isPreview != true { activity = nil }
            for stale in staleActivities {
                guard !Task.isCancelled else { return }
                await stale.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        // A real call takes ownership before it publishes any activity content.
        await endPreview()
        guard !Task.isCancelled else { return }
        let state = TincallCallAttributes.ContentState(status: status, startedAt: record.startedAt, isMuted: isMuted,
                                                     microphoneAvailable: microphoneAvailable, isSpeakerEnabled: isSpeakerEnabled,
                                                     audioActivity: audioActivity, displayName: record.roleName,
                                                     avatarContactID: callAvatar(callID: record.id, contactID: record.roleID))
        let content = ActivityContent(state: state, staleDate: nil)
        if activity?.attributes.callID != record.id,
           let delivered = Activity<TincallCallAttributes>.activities.first(where: { $0.attributes.callID == record.id && !$0.attributes.isPreview }) {
            activity = delivered
        }
        if let current = activity, current.attributes.callID == record.id {
            await current.update(content)
            TincallMicrophoneDiagnostics.record(microphoneAvailable ? (isMuted ? .activityMuted : .activityUnmuted) : .activityUnavailable)
        } else {
            let previous = activity
            activity = nil
            if let previous { await previous.end(nil, dismissalPolicy: .immediate) }
            guard !Task.isCancelled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            guard UIApplication.shared.applicationState == .active else {
                CallAudioDiagnostics.record(.independentAudioStage, phase: "call_activity_waiting_for_foreground")
                return
            }
            let avatarContactID = prepareAvatar(for: record.roleID)
            do {
                activity = try Activity.request(attributes: TincallCallAttributes(callID: record.id, name: record.roleName,
                                                                                avatarContactID: avatarContactID), content: content)
                CallAudioDiagnostics.record(.independentAudioStage, phase: "call_activity_started")
                TincallMicrophoneDiagnostics.record(microphoneAvailable ? (isMuted ? .activityMuted : .activityUnmuted) : .activityUnavailable)
                errorMessage = nil
            } catch {
                let failure = error as NSError
                CallAudioDiagnostics.record(.independentAudioStage, phase: "call_activity_start_failed",
                    errorDomain: failure.domain, errorCode: failure.code)
                errorMessage = String(localized: "锁屏通话卡片未能显示，通话仍可继续。")
                activity = nil
            }
        }
    }

    func updatePreview(id: UUID, contactID: UUID?, name: String,
                       state: TincallCallAttributes.ContentState) async {
        guard !Task.isCancelled, TincallRuntime.shared.coordinator?.isCallActive != true else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if let current = activity, current.attributes.isPreview, current.attributes.callID == id {
            await current.update(content)
            return
        }

        let staleActivities = Activity<TincallCallAttributes>.activities
        activity = nil
        for stale in staleActivities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
        // Ending an activity suspends: recheck in case the page closed or a real call began.
        guard !Task.isCancelled, TincallRuntime.shared.coordinator?.isCallActive != true,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let avatarContactID = contactID.flatMap { prepareAvatar(for: $0) }
        do {
            activity = try Activity.request(attributes: TincallCallAttributes(callID: id, name: name,
                                                                            avatarContactID: avatarContactID,
                                                                            isPreview: true), content: content)
        } catch {
            // Appearance previews remain usable even when ActivityKit cannot display a card.
        }
    }

    func endPreview(id: UUID? = nil) async {
        let previews = Activity<TincallCallAttributes>.activities.filter {
            $0.attributes.isPreview && (id == nil || $0.attributes.callID == id)
        }
        if let current = activity, current.attributes.isPreview,
           id == nil || current.attributes.callID == id {
            activity = nil
        }
        for preview in previews {
            await preview.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func callAvatar(callID: UUID, contactID: UUID?) -> UUID? {
        if preparedAvatarCallID != callID {
            preparedAvatarCallID = callID
            preparedAvatarContactID = contactID.flatMap(prepareAvatar(for:))
        }
        return preparedAvatarContactID
    }

    private func prepareAvatar(for contactID: UUID) -> UUID? {
        guard let url = TincallCallAvatar.fileURL(for: contactID) else { return nil }
        // Match the active CallScreen's role lookup and manual/system-contact selection.
        let role = TincallRuntime.shared.configuration?.roles.first { $0.id == contactID }
        guard let data = role?.displayAvatarData, let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let size = CGSize(width: 120, height: 120)
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let rect = CGRect(x: (size.width - image.size.width * scale) / 2,
                          y: (size.height - image.size.height * scale) / 2,
                          width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Pixels, independent of the phone's display scale.
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: rect)
        }
        for quality in [0.85, 0.6, 0.35, 0.1] {
            guard let jpeg = thumbnail.jpegData(compressionQuality: quality), jpeg.count <= 50_000 else { continue }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Allow the widget to read after locking, once the device has been unlocked.
                try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return contactID
            } catch {
                break
            }
        }
        // Publish no ID on failure, so even an undeletable old file cannot be displayed.
        try? FileManager.default.removeItem(at: url)
        return nil
    }
}
