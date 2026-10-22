import Foundation

@main
struct AutomaticCloudSyncChecks {
    @MainActor static func main() async throws {
        var ready = true
        var runs = 0
        var running = 0
        var maximumRunning = 0
        var gate: CheckedContinuation<Void, Never>?
        let controller = AutomaticCloudSyncController(canSynchronize: { ready }, synchronize: {
            runs += 1
            running += 1
            maximumRunning = max(maximumRunning, running)
            await withCheckedContinuation { gate = $0 }
            running -= 1
        })
        defer { controller.cancel() }

        controller.request()
        try await Task.sleep(for: .milliseconds(100))
        controller.request()
        controller.request()
        try await waitUntil { runs == 1 }
        try expect(maximumRunning == 1, "local changes coalesce into one operation")
        gate?.resume(); gate = nil
        try await Task.sleep(for: .milliseconds(850))
        try expect(runs == 1, "changes received before a pass do not cause a redundant pass")

        ready = false
        controller.request()
        try await Task.sleep(for: .milliseconds(850))
        try expect(runs == 1, "a manual operation blocks automatic network work")
        ready = true
        try await waitUntil { runs == 2 }
        controller.request()
        controller.request()
        try await Task.sleep(for: .milliseconds(850))
        try expect(runs == 2, "a second automatic pass cannot overlap the first")
        gate?.resume(); gate = nil
        try await waitUntil { runs == 3 }
        try expect(maximumRunning == 1, "changes during synchronization get one serialized follow-up")
        gate?.resume(); gate = nil
        try await Task.sleep(for: .milliseconds(50))

        controller.request()
        controller.cancel()
        try await Task.sleep(for: .milliseconds(850))
        try expect(runs == 3, "leaving the foreground cancels a pending pass")

        controller.request()
        controller.cancel()
        controller.request()
        try await waitUntil { runs == 4 }
        controller.cancel()
        controller.request()
        gate?.resume(); gate = nil
        try await waitUntil { runs == 5 }
        try expect(maximumRunning == 1, "re-entering during cancellation retains the new request without overlap")
        controller.cancel()
        gate?.resume(); gate = nil
        try await Task.sleep(for: .milliseconds(850))
        try expect(runs == 5, "cancellation does not schedule another pass")
        print("Automatic cloud synchronization scheduling checks passed")
    }

    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(predicate(), "scheduled pass completes within the deadline")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "AutomaticCloudSyncChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
