// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct RequestLogResponsivenessChecks {
    @MainActor static func main() async throws {
        struct Archive: Encodable {
            let version = 2
            let calls: [RequestLogCall] = []
            let entries: [RequestLogEntry]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallLogResponsiveness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let fixture = (0..<15_000).map { index in
            RequestLogEntry(id: UUID(), time: now.addingTimeInterval(-Double(index)), service: .mcp,
                step: .callControl, context: nil, segment: nil, duration: 0.1, outcome: .succeeded,
                connectionName: "Synthetic connection")
        }
        try JSONEncoder().encode(Archive(entries: fixture)).write(to: directory.appendingPathComponent("requests.json"))
        let store = RequestLogStore(directory: directory)
        await store.flushPendingWrites()
        let start = ProcessInfo.processInfo.systemUptime
        let span = store.begin(service: .mcp, step: .callControl)
        span.request("Synthetic current call check")
        span.succeed("Synthetic no incoming call")
        span.finish()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try FileHandle.standardError.write(contentsOf: Data("Main-actor log update: \(Int(elapsed * 1000)) ms with \(fixture.count) retained requests\n".utf8))
        // A long index write overlaps further updates to the same request body.
        let callID = UUID()
        let updating = store.begin(service: .mcp, step: .events, context: RequestLogContext(callID: callID))
        for index in 0..<6 {
            updating.request("Synthetic update \(index)")
            await Task.yield()
        }
        store.markHangUp(callID: callID)
        updating.succeed("Synthetic late completion"); updating.finish()
        await store.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        let saved = try reopened.load(Array(reopened.entries.suffix(2)))
        guard reopened.entries.count == fixture.count + 2,
              saved[0].responseText == "Synthetic no incoming call",
              saved[1].requestText == "Synthetic update 5",
              saved[1].responseText == "Synthetic late completion",
              saved[1].errorCode == "call_hang_up", saved[1].outcome == .cancelled else {
            throw NSError(domain: "RequestLogResponsivenessChecks", code: 2)
        }
        await reopened.flushPendingWrites()
        guard elapsed < 0.05 else {
            throw NSError(domain: "RequestLogResponsivenessChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A routine incoming-call check blocks UI work for more than 50 ms"])
        }
        print("PASS: prompt incoming-call logging, updates during saves, hangup and complete restart recovery")
    }
}
