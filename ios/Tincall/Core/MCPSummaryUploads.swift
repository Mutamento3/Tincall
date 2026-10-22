// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Owns summary upload receipts and task ordering across connector clients.
/// The client supplies credential validation and a transport that logs request failures.
@MainActor
final class MCPSummaryUploads {
    private static var tasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private struct SummaryUploadState: Codable {
        var requestID: UUID
        var completed = false
        var attempts = 0
        var retryAfter: Date?
    }
    private let summaryUploadDirectory: URL?
    private let logs: RequestLogStore

    init(logs: RequestLogStore, directory: URL? = nil) {
        self.logs = logs
        summaryUploadDirectory = directory
    }

    /// Best effort: the durable local summary remains available for the next sync.
    /// Serialize across client instances so a sync cannot overwrite a newer generation.
    func upload(for record: CallRecord, connection: ConnectionProfile,
                validate: @escaping @MainActor () throws -> Void,
                send: @escaping @MainActor (_ callID: UUID, _ requestID: UUID) async throws -> Void) async {
        guard record.callMode == .mcp, record.externalConnectionID == connection.id,
              let callID = record.externalCallID, record.endedAt != nil,
              record.summaryStatus == .completed, !record.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let summaryVersion = record.summaryUploadRequestID?.uuidString ?? "legacy"
        let uploadKey = [connection.id.uuidString, connection.endpoint?.absoluteString ?? "", callID.uuidString, summaryVersion]
            .joined(separator: "|")
        let context = RequestLogContext(callID: record.id)
        let key = "\(connection.id)/\(callID)"
        let previous = Self.tasks[key]?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            do {
                try validate()
                let file = try self.summaryUploadStateURL(connectionID: connection.id, callID: callID)
                var states = try self.readSummaryUploadStates(file)
                var state = states[uploadKey] ?? SummaryUploadState(requestID: record.summaryUploadRequestID ?? UUID())
                guard !state.completed, state.retryAfter.map({ $0 <= Date() }) ?? true else { return }
                // Persist before sending: interruption/relaunch retains the request ID and retry delay.
                state.attempts = min(state.attempts + 1, 7)
                state.retryAfter = Date().addingTimeInterval(min(60 * pow(2, Double(state.attempts - 1)), 3600))
                states[uploadKey] = state
                try self.saveSummaryUploadStates(states, to: file)
                do {
                    try await send(callID, state.requestID)
                } catch {
                    // The transport logs failures; the saved retry delay prevents sync-triggered loops.
                    return
                }
                state.completed = true
                state.retryAfter = nil
                states[uploadKey] = state
                try self.saveSummaryUploadStates(states, to: file)
            } catch {
                let log = self.logs.begin(service: .mcp, step: .summary, context: context, connectionName: connection.name)
                log.request(String(localized: "回传通话摘要")); log.fail(error); log.finish()
            }
        }
        Self.tasks[key] = (id, task)
        await task.value
        if Self.tasks[key]?.id == id { Self.tasks.removeValue(forKey: key) }
    }

    private func summaryUploadStateURL(connectionID: UUID, callID: UUID) throws -> URL {
        let root = try summaryUploadDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Tincall/SummaryUploads", isDirectory: true)
        let directory = root.appendingPathComponent(connectionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(callID.uuidString).json")
    }

    private func readSummaryUploadStates(_ file: URL) throws -> [String: SummaryUploadState] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: SummaryUploadState].self, from: Data(contentsOf: file))
    }

    private func saveSummaryUploadStates(_ states: [String: SummaryUploadState], to file: URL) throws {
        try JSONEncoder().encode(states).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
