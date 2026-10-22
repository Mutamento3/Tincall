// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Owns summary configuration and task lifetime, without keeping another copy of call records.
@MainActor
final class CallSummaryTasks {
    enum Update {
        case generating
        case completed(String)
        case failed(Error)
    }

    private struct Configuration {
        let connection: ConnectionProfile
        let role: CallRole
    }
    private let model: ChatCompletionClient
    private var configurations: [UUID: Configuration] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(model: ChatCompletionClient) { self.model = model }

    func configure(callID: UUID, role: CallRole, connection: ConnectionProfile?) {
        configurations[callID] = connection.map { Configuration(connection: $0, role: role) }
    }

    func isConfigured(_ callID: UUID) -> Bool { configurations[callID] != nil }
    func isRunning(_ callID: UUID) -> Bool { tasks[callID] != nil }

    func forget(_ callID: UUID) {
        guard !isRunning(callID) else { return }
        configurations.removeValue(forKey: callID)
    }

    /// Read the transcript after the interrupted generation has finished unwinding.
    /// Keep the task registered through the final save/upload so deletion cannot race it.
    func start(callID: UUID, after generation: Task<Void, Never>?, userName: String,
               record: @escaping @MainActor () -> CallRecord?,
               onUpdate: @escaping @MainActor (Update) async -> Void) {
        guard !isRunning(callID), let configuration = configurations[callID] else { return }
        tasks[callID] = Task { [self] in
            defer { tasks.removeValue(forKey: callID) }
            await generation?.value
            guard let value = record() else { return }
            await onUpdate(.generating)
            do {
                let messages = CallSummaryRequestBuilder.messages(
                    prompt: configuration.role.effectiveSummaryPrompt,
                    targetLength: configuration.role.effectiveSummaryMaxCharacters,
                    transcript: CallSummaryRequestBuilder.transcript(from: value.messages),
                    userName: userName, contactName: value.roleName)
                let summary = try await model.complete(connection: configuration.connection, messages: messages,
                                                       logContext: RequestLogContext(callID: callID))
                await onUpdate(.completed(summary))
            } catch {
                await onUpdate(.failed(error))
            }
        }
    }
}
