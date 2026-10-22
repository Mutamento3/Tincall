// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import StoreKit
import StoreKitTest

@MainActor enum CallAccessStoreChecks {
    static func run() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var entitlement = CallAccessEntitlements(trialStartedAt: start)
        precondition(entitlement.state(at: start) == .trial(until: start.addingTimeInterval(604800)))
        precondition(entitlement.state(at: start.addingTimeInterval(604799)).allowsCalls)
        precondition(entitlement.state(at: start.addingTimeInterval(604800)) == .expired)
        precondition(!entitlement.state(at: start.addingTimeInterval(-1)).allowsCalls)
        entitlement.trialRevoked = true
        precondition(!entitlement.state(at: start).allowsCalls)
        entitlement.purchased = true
        precondition(entitlement.state(at: start.addingTimeInterval(604801)) == .purchased)
        print("ACCESS_CHECK PASS trial boundaries, revocation and permanent unlock")

        let store = CallAccessStore()
        if !CallAccessStore.isStoreBuild {
            await store.refresh()
            await store.loadProducts()
            try await store.requireAccess()
            precondition(store.state == .sourceBuild && store.products.isEmpty)
            print("ACCESS_CHECK PASS self-build unrestricted without products")
            return
        }

        let session = try SKTestSession(configurationFileNamed: "Tincall")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()
        defer { session.clearTransactions() }
        store.start()
        await store.refresh()
        print("ACCESS_CHECK initial state \(store.state)")
        await store.loadProducts()
        print("ACCESS_CHECK loaded products \(store.products.count)")
        precondition(store.state == .notStarted && !store.canCall)
        guard let trial = store.trialProduct, let unlock = store.unlockProduct else {
            throw TincallError(message: "Local StoreKit catalog missing")
        }
        precondition(trial.price == 0 && unlock.price == Decimal(string: "2.99"))
        do { try await store.requireAccess(); preconditionFailure("Unclaimed trial must not grant calls") }
        catch is TincallError { }
        await store.purchase(trial)
        print("ACCESS_CHECK trial result \(store.state)")
        guard case .trial(let firstEnd) = store.state else { preconditionFailure("Trial purchase did not grant access: \(store.state), \(store.message ?? "")") }
        try await store.requireAccess()
        let reopened = CallAccessStore()
        await reopened.refresh()
        print("ACCESS_CHECK reopened")
        precondition(reopened.state == .trial(until: firstEnd), "Reopening must not reset the seven-day window")
        await store.restore()
        print("ACCESS_CHECK restored")
        precondition(store.state == .trial(until: firstEnd), "Restoring must preserve the original trial date")
        print("ACCESS_CHECK PASS real StoreKit trial purchase, reopen and restore")

        session.clearTransactions()
        _ = try await session.buyProduct(identifier: CallAccessStore.trialID,
                                        options: [.purchaseDate(Date().addingTimeInterval(-8 * 86400))])
        await store.refresh()
        precondition(store.state == .expired && !store.canCall)
        await store.purchase(trial)
        precondition(store.state == .expired, "Claiming the trial again must not restart it")
        await store.purchase(unlock)
        precondition(store.state == .purchased && store.canCall)
        let purchased = CallAccessStore()
        await purchased.refresh()
        precondition(purchased.state == .purchased)
        guard case .verified(let transaction)? = await StoreKit.Transaction.latest(for: CallAccessStore.unlockID) else {
            preconditionFailure("Missing verified unlock transaction")
        }
        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitUntil { store.state == .expired }
        precondition(store.state == .expired && !store.canCall)
        print("ACCESS_CHECK PASS expired trial, buyout, relaunch and refund")

        session.clearTransactions()
        session.askToBuyEnabled = true
        await store.refresh()
        await store.purchase(unlock)
        precondition(!store.canCall && store.state == .notStarted && store.message != nil)
        guard let pending = session.allTransactions().last else { preconditionFailure("Pending purchase missing") }
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitUntil { store.state == .purchased }
        precondition(store.state == .purchased && store.canCall)
        print("ACCESS_CHECK PASS pending purchase grants access only after approval")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TincallError(message: "StoreKit transaction update was not delivered within five seconds")
    }
}
