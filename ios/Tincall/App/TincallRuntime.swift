import Observation
import UIKit

/// Created at application launch so VoIP registration does not depend on a visible SwiftUI page.
@MainActor @Observable
final class TincallRuntime {
    static let shared = TincallRuntime()
    private(set) var configuration: LocalConfigurationStore?
    private(set) var records: CallRecordStore?
    private(set) var coordinator: CallCoordinator?
    private(set) var loadError: String?
    private(set) var cloudSync: CloudSyncStore?
    private(set) var cloudSyncLoadingError: String?
    @ObservationIgnored private var isAppActive = false
    @ObservationIgnored private var lastAccessState: CallAccessState?
    @ObservationIgnored private var automaticSync: AutomaticCloudSyncController?
    let incoming = IncomingCallController()
    let callActivity = CallActivityController()
    let access = CallAccessStore.shared

    func load() {
        guard coordinator == nil else { return }
        access.start()
        do {
            let configuration = try LocalConfigurationStore()
            let records = try CallRecordStore()
            try records.recoverUnfinishedCalls()
            let voice = TincallVoiceService()
            let incoming = self.incoming
            let coordinator = CallCoordinator(voice: voice,
                                              transcriptCorrections: { configuration.speechRecognitionCorrections },
                                              summaryUserName: { configuration.userProfile.name })
            coordinator.onSaveRecord = { record in
                try records.save(record)
                RequestLogStore.shared.registerCall(id: record.id, startedAt: record.startedAt, mode: record.callMode)
                if record.endedAt != nil {
                    incoming.endAcceptedCall(record.id)
                    self.callActivity.clearIncomingSuppression(callID: record.id)
                }
            }
            coordinator.onSaveAudio = { try records.saveAudio(recordID: $0, segment: $1) }
            coordinator.onSaveImages = { try records.saveImages(recordID: $0, messageID: $1, images: $2) }
            coordinator.onSpeechRecognitionUsed = { id in
                try configuration.saveDefaultSTTConnection(id)
            }
            coordinator.onLoadImages = { recordID, message in
                try (message.images ?? []).map { try Data(contentsOf: records.imageURL($0, recordID: recordID, messageID: message.id)) }
            }
            coordinator.onDiscardImages = { recordID, messageID, images in
                for image in images { try FileManager.default.removeItem(at: records.imageURL(image, recordID: recordID, messageID: messageID)) }
            }
            records.canDeleteRecord = { [weak coordinator] in coordinator?.canForgetRecord($0) != false }
            records.onDeleteRecord = { [weak coordinator] in coordinator?.forgetRecord($0) }
            self.configuration = configuration
            self.records = records
            self.coordinator = coordinator
            callActivity.startObserving(coordinator)
            do { cloudSync = try CloudSyncStore(records: records) }
            catch { cloudSyncLoadingError = error.localizedDescription }
            automaticSync = AutomaticCloudSyncController(canSynchronize: { [weak self] in
                self?.canAutomaticallySynchronize == true
            }, synchronize: { [weak self] in
                guard let self, let cloudSync = self.cloudSync, let connection = self.cloudSyncConnection else { return }
                await cloudSync.synchronizeAutomatically(connection: connection)
            })
            observeCloudSyncChanges()
            requestAutomaticSync()
            loadError = nil
            incoming.canAcceptCall = { [weak coordinator, access] in
                coordinator?.isCallActive == false && (access.state == .checking || access.canCall)
            }
            incoming.canUseConnections = { role, connector in
                DataSharingConsent.permitsIncomingCall(role: role, connector: connector, connections: configuration.connections,
                                                      defaultSTT: configuration.defaultSTTConnectionID)
            }
            incoming.onValidateCallAccess = { [access] in try await access.requireAccess() }
            incoming.onResolveRole = { identifier, mode, connectionID in
                return configuration.roles.first { role in
                    guard role.effectiveCallMode == mode else { return false }
                    if mode == .standalone { return role.id.uuidString.lowercased() == identifier.lowercased() }
                    return role.externalRoleID == identifier
                        && role.externalConnectionID == connectionID
                }
            }
            incoming.onRing = { [weak callActivity, weak incoming] callID, role, connector in
                // Re-apply caller matching details for every ring, including warm redials.
                incoming?.refreshReportedCallDetails(roles: configuration.roles)
                // CallKit is the only incoming-call presentation. Do not create
                // a second Tincall Live Activity or remote banner while ringing.
                callActivity?.suppressIncoming(callID: callID)
                var resolved = role
                if let id = configuration.defaultSTTConnectionID { resolved.sttConnectionID = id }
                try coordinator.prepareIncomingOpening(callID: callID, role: resolved,
                    connections: configuration.connections, retention: configuration.retention, historyRecords: records.records)
            }
            incoming.onPreparePresentation = { [weak callActivity] callID, _, _ in
                callActivity?.clearIncomingSuppression(callID: callID)
                await callActivity?.refresh(coordinator)
            }
            incoming.onNeedsRemoteActivity = { [weak callActivity, weak coordinator] callID in
                guard UIApplication.shared.applicationState != .active,
                      coordinator?.phase == .active, coordinator?.record?.id == callID else { return false }
                return callActivity?.needsRemoteStart(callID: callID) == true
            }
            incoming.onCancelRinging = { [weak callActivity] callID in
                callActivity?.endIncoming(callID: callID)
                callActivity?.clearIncomingSuppression(callID: callID)
                coordinator.cancelIncomingOpening(callID: callID)
            }
            incoming.onPrepare = { callID, role, connector in
                var resolved = role
                if let id = configuration.defaultSTTConnectionID { resolved.sttConnectionID = id }
                try await coordinator.prepareIncoming(callID: callID, role: resolved, connector: connector,
                    connections: configuration.connections, retention: configuration.retention, historyRecords: records.records)
            }
            incoming.onAccept = { callID, _, _ in
                try await coordinator.confirmIncoming(callID: callID)
            }
            incoming.onBeginMedia = { callID, _, _ in
                guard let prepared = coordinator.preparedIncoming, prepared.session.callID == callID,
                      coordinator.session == prepared.session else { throw CancellationError() }
                voice.setSpeechInterruptionEnabled(coordinator.speechInterruptionEnabled)
                try await voice.prepareIncomingAudio(session: prepared.session, configuration: prepared.configuration)
            }
            incoming.onReleaseMedia = { callID in
                guard coordinator.isCallActive, coordinator.record?.id == callID else { throw CancellationError() }
                try await voice.resumeAfterSystemAudioHandoff()
                // Request the app only after the system presentation releases
                // it. This request does not wait for remote acceptance.
                if UIApplication.shared.applicationState != .active, let url = URL(string: "tincall://call") {
                    let opened = await UIApplication.shared.open(url, options: [:])
                    CallAudioDiagnostics.record(.independentAudioStage, flag: opened, phase: "incoming_open_after_release_result")
                }
            }
            incoming.onConnected = { callID in
                try await coordinator.activatePreparedIncoming(callID: callID)
            }
            incoming.onSetMuted = { callID, muted in
                guard coordinator.phase == .active, coordinator.record?.id == callID else { throw CancellationError() }
                if coordinator.isMuted != muted { await coordinator.toggleMute() }
                guard coordinator.isMuted == muted else {
                    throw TincallError(message: String(localized: "无法切换麦克风，请在 App 内重试"))
                }
            }
            incoming.onEnd = { callID, role, connector in
                await coordinator.declineIncoming(callID: callID, role: role, connector: connector)
            }
            callActivity.observePushStarts { [weak incoming] token in incoming?.updateActivityStartToken(token) }
            coordinator.restorePendingExternalControls(from: records.records, connections: configuration.connections)
            coordinator.resumePendingSummaries(from: records.records, connections: configuration.connections, roles: configuration.roles)
            updateForegroundIncoming()
            Task {
                await configuration.refreshLinkedContacts()
                incoming.refreshReportedCallDetails(roles: configuration.roles)
            }
        } catch {
            loadError = (error as? TincallError)?.message
                ?? String(localized: "读取失败（\((error as NSError).code)）。原数据已保留，修复存储后可重试。")
        }
    }
    func setAppActive(_ active: Bool) {
        isAppActive = active
        if active { Task { await access.refresh() } }
        incoming.setAppActive(active)
        if active, let coordinator {
            Task { await callActivity.refresh(coordinator) }
        }
        updateForegroundIncoming()
        requestAutomaticSync()
    }

    private func updateForegroundIncoming() {
        let connections = configuration?.connections ?? []
        if lastAccessState != access.state {
            let previous = lastAccessState
            lastAccessState = access.state
            if previous != nil && previous != .checking { incoming.refreshCallAccess() }
        }
        incoming.updateConnections(connections)
        incoming.monitorForeground(connections: connections, active: isAppActive && access.canCall)
    }

    func refreshDataSharingConsent() {
        incoming.dismissError()
        incoming.monitorForeground(connections: [], active: false)
        updateForegroundIncoming()
        if incoming.isEnabled, let configuration {
            Task { await incoming.restore(with: configuration.connections) }
        }
        requestAutomaticSync()
    }

    private var cloudSyncConnection: ConnectionProfile? {
        configuration?.connections.first { $0.id == cloudSync?.selectedConnectionID && $0.provider == .genericConnector }
    }

    private var canAutomaticallySynchronize: Bool {
        isAppActive && coordinator?.isCallActive == false && cloudSync?.automaticSyncEnabled == true &&
            cloudSyncConnection != nil && cloudSync?.isBusy == false
    }

    private func requestAutomaticSync() {
        guard isAppActive, coordinator?.isCallActive == false, cloudSync?.automaticSyncEnabled == true,
              cloudSyncConnection != nil else {
            automaticSync?.cancel()
            return
        }
        automaticSync?.request()
    }

    private func observeCloudSyncChanges() {
        withObservationTracking {
            _ = configuration?.connections
            _ = configuration?.roles
            _ = records?.records
            _ = coordinator?.isCallActive
            _ = cloudSync?.automaticSyncEnabled
            _ = cloudSync?.selectedConnectionID
            _ = cloudSync?.mediaEnabled
            _ = incoming.isEnabled
            _ = incoming.registrationStates
            _ = access.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeCloudSyncChanges()
                self?.updateForegroundIncoming()
                self?.requestAutomaticSync()
            }
        }
    }
}

final class TincallAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TincallRuntime.shared.load()
        return true
    }
}
