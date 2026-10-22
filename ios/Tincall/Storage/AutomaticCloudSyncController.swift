// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Coalesce local changes and serialize automatic passes, including cancellation during a request.
@MainActor
final class AutomaticCloudSyncController {
    private let canSynchronize: () -> Bool
    private let synchronize: () async -> Void
    private var operation: Task<Void, Never>?
    private var requested = false

    init(canSynchronize: @escaping () -> Bool, synchronize: @escaping () async -> Void) {
        self.canSynchronize = canSynchronize
        self.synchronize = synchronize
    }

    func request() {
        requested = true
        startIfNeeded()
    }

    func cancel() {
        requested = false
        operation?.cancel()
    }

    private func startIfNeeded() {
        guard operation == nil, requested else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.operation = nil
                if self.requested { self.startIfNeeded() }
            }
            while self.requested && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                guard self.canSynchronize() else { continue }
                self.requested = false
                await self.synchronize()
            }
        }
    }
}
