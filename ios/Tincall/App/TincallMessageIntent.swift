// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AppIntents
import UIKit
import UniformTypeIdentifiers

struct CheckTincallCallIntent: AppIntent {
    static let title: LocalizedStringResource = "检查当前通话"
    static let description = IntentDescription("确认 Tincall 正在通话，再继续发送文字或截图。")
    static let openAppWhenRun = false
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let call = try TincallShortcutMessages.activeCall(TincallRuntime.shared.coordinator)
        return .result(value: call.id.uuidString)
    }
}

struct SendTincallMessageIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "给 TA 发消息"
    static let description = IntentDescription("给当前正在通话的对方发送文字或图片。")
    static let openAppWhenRun = false
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "要说的文字", inputOptions: .init(keyboardType: .default, multiline: true))
    var message: String?

    @Parameter(title: "要发送的图片", description: "可接收截图或照片，一次最多 4 张。", supportedContentTypes: [.image])
    var images: [IntentFile]?

    @Parameter(title: "通话标识", description: "由检查当前通话动作传入，避免发送到另一通电话。")
    var callID: String?

    static var parameterSummary: some ParameterSummary {
        Summary("发消息：\(\.$message)，图片：\(\.$images)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let call = try TincallShortcutMessages.activeCall(TincallRuntime.shared.coordinator, expectedCallID: callID)
        let attachments = images ?? []
        var text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty {
            do {
                text = try await $message.requestValue("要跟 TA 说什么？")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                return .result()
            }
        }
        guard !text.isEmpty || !attachments.isEmpty else { return .result() }
        guard attachments.count <= 4 else { throw TincallError(message: String(localized: "一次最多发送 4 张图片")) }
        var imageData: [Data] = []
        for image in attachments {
            let jpeg = try await Task.detached { try CallImageCompression.jpeg(data: image.data) }.value
            try Task.checkCancellation()
            imageData.append(jpeg)
        }
        try Task.checkCancellation()
        let delivery = TincallShortcutDelivery()
        delivery.begin()
        do { try TincallShortcutMessages.send(in: call.coordinator, callID: call.id, text: text, images: imageData) }
        catch { delivery.finish(); throw error }
        delivery.waitForPlayback(in: call.coordinator, callID: call.id)
        return .result()
    }
}

/// Covers the network-to-audio gap after the shortcut has already finished.
@MainActor
private final class TincallShortcutDelivery {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var waitTask: Task<Void, Never>?

    func begin() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Tincall call message") { [weak self] in
            Task { @MainActor [weak self] in self?.finish() }
        }
    }

    func waitForPlayback(in coordinator: CallCoordinator, callID: UUID) {
        waitTask = Task { [self, weak coordinator] in
            defer { finish() }
            while let coordinator, coordinator.record?.id == callID, coordinator.isCallActive,
                  coordinator.generation == .generating || coordinator.playback == .synthesizing {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    func finish() {
        waitTask?.cancel(); waitTask = nil
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}

struct TincallAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendTincallMessageIntent(),
            phrases: ["用 \(.applicationName) 给 TA 发消息"],
            shortTitle: "给 TA 发消息",
            systemImageName: "message"
        )
    }
}
