import Foundation

/// Sends only through the current call; never creates a separate conversation.
@MainActor
enum TincallShortcutMessages {
    static func activeCall(_ coordinator: CallCoordinator?, expectedCallID: String? = nil) throws -> (coordinator: CallCoordinator, id: UUID) {
        guard let coordinator, coordinator.isCallActive, let callID = coordinator.record?.id else {
            throw TincallError(message: String(localized: "当前没有正在进行的通话，请先在 Tincall 中开始通话"))
        }
        if let expectedCallID, UUID(uuidString: expectedCallID) != callID {
            throw TincallError(message: String(localized: "原通话已结束，请重新运行快捷指令"))
        }
        return (coordinator, callID)
    }

    static func send(in coordinator: CallCoordinator, callID: UUID, text: String, images: [Data]) throws {
        _ = try activeCall(coordinator, expectedCallID: callID.uuidString)
        guard coordinator.canSend else {
            throw TincallError(message: String(localized: "通话正在连接，请稍后再发送"))
        }
        // The transcript's sendText interrupts a busy turn; a shortcut must leave it alone.
        guard !coordinator.canInterrupt else {
            throw TincallError(message: String(localized: "TA 正在回复或说话，请稍后再发送"))
        }
        guard coordinator.sendText(text, images: images) else { throw Self.failure(coordinator) }
        // The runtime owns generation and speech after this action returns.
    }

    private static func failure(_ coordinator: CallCoordinator) -> TincallError {
        TincallError(message: coordinator.errorMessage
            ?? String(localized: "消息未能发送，请打开 Tincall 检查通话状态"))
    }
}
