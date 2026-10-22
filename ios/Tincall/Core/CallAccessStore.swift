import Foundation
import Observation
import StoreKit

enum CallAccessState: Equatable {
    case sourceBuild, checking, notStarted, trial(until: Date), expired, purchased, unavailable

    var allowsCalls: Bool {
        switch self {
        case .sourceBuild, .trial, .purchased: true
        default: false
        }
    }
}

/// Derived only from verified StoreKit transactions, never from a local trial-start flag.
struct CallAccessEntitlements {
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60
    var trialStartedAt: Date?
    var trialRevoked = false
    var purchased = false

    func state(at now: Date) -> CallAccessState {
        if purchased { return .purchased }
        guard let start = trialStartedAt else { return .notStarted }
        let end = start.addingTimeInterval(Self.trialDuration)
        guard !trialRevoked, now >= start, now < end else { return .expired }
        return .trial(until: end)
    }
}

@MainActor @Observable
final class CallAccessStore {
    static let trialID = "com.tincall.app.trial7days"
    static let unlockID = "com.tincall.app.lifetime"
    static let shared = CallAccessStore()
    static var isStoreBuild: Bool {
        #if TINCALL_APP_STORE
        true
        #else
        false
        #endif
    }

    private(set) var state: CallAccessState = isStoreBuild ? .checking : .sourceBuild
    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var message: String?
    private(set) var productError: String?
    var showsUnlock = false
    @ObservationIgnored private var entitlements = CallAccessEntitlements()
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var verificationFailed = false
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    var canCall: Bool {
        if !Self.isStoreBuild { return true }
        return hasLoaded && !verificationFailed && entitlements.state(at: Date()).allowsCalls
    }

    var trialProduct: Product? { products.first { $0.id == Self.trialID && $0.type == .nonConsumable && $0.price == 0 } }
    var unlockProduct: Product? { products.first { $0.id == Self.unlockID && $0.type == .nonConsumable && $0.price > 0 } }
    var pushValidUntil: Date? {
        guard Self.isStoreBuild, case .trial(let end) = entitlements.state(at: Date()) else { return nil }
        return end
    }

    func start() {
        guard Self.isStoreBuild, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                guard [Self.trialID, Self.unlockID].contains(result.unsafePayloadValue.productID) else { continue }
                await self.refresh()
                if case .verified(let transaction) = result { await transaction.finish() }
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard Self.isStoreBuild else { return }
        let previous = refreshTask
        let identity = UUID()
        refreshID = identity
        let task = Task<Void, Never> { [weak self] in
            await previous?.value
            await self?.readEntitlements()
        }
        refreshTask = task
        await task.value
        if refreshID == identity { refreshTask = nil }
    }

    private func readEntitlements() async {
        var value = CallAccessEntitlements()
        var failed = false
        for await result in StoreKit.Transaction.currentEntitlements(for: Self.unlockID) {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.unlockID, transaction.productType == .nonConsumable else {
                failed = true
                continue
            }
            if transaction.revocationDate == nil { value.purchased = true }
        }
        for await result in StoreKit.Transaction.all {
            guard result.unsafePayloadValue.productID == Self.trialID else { continue }
            guard case .verified(let transaction) = result else { failed = true; continue }
            guard transaction.productType == .nonConsumable else { failed = true; continue }
            value.trialStartedAt = min(value.trialStartedAt ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate)
            value.trialRevoked = value.trialRevoked || transaction.revocationDate != nil
        }
        entitlements = value
        hasLoaded = true
        verificationFailed = failed
        state = failed ? .unavailable : value.state(at: Date())
        expiryTask?.cancel()
        if case .trial(let end) = state {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
                catch { return }
                guard let self else { return }
                self.state = self.entitlements.state(at: Date())
            }
        }
    }

    func requireAccess() async throws {
        if Self.isStoreBuild && !hasLoaded { await refresh() }
        try requireCurrentAccess()
    }

    func requireCurrentAccess() throws {
        guard canCall else {
            throw TincallError(message: state == .checking || state == .unavailable
                ? String(localized: "购买状态尚未确认，请在设置的「试用与解锁」中重试或恢复购买")
                : String(localized: "请在设置的「试用与解锁」中开始免费试用或永久解锁，再发起或接听通话"))
        }
    }

    func loadProducts() async {
        guard Self.isStoreBuild, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        productError = nil
        do {
            products = try await Product.products(for: [Self.trialID, Self.unlockID])
            if trialProduct == nil || unlockProduct == nil {
                productError = String(localized: "暂时无法取得购买项目，请稍后重试。已购买的用户可恢复购买。")
            }
        } catch {
            productError = String(localized: "无法连接 App Store，请检查网络后重试。")
        }
    }

    func purchase(_ product: Product) async {
        guard Self.isStoreBuild, !isPurchasing,
              product.id == Self.unlockID || (product.id == Self.trialID && state == .notStarted),
              product.type == .nonConsumable,
              product.id != Self.trialID || (product.price == 0 && unlockProduct != nil) else { return }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    await refresh()
                    message = String(localized: "购买记录未通过验证，请重试或恢复购买。")
                    return
                }
                await refresh()
                await transaction.finish()
            case .pending:
                message = String(localized: "购买正在等待确认，完成后会自动更新解锁状态。")
            case .userCancelled: break
            @unknown default:
                message = String(localized: "购买尚未完成，请稍后重试。")
            }
        } catch {
            message = String(localized: "购买未能完成，请稍后重试。若已扣款，请使用恢复购买。")
        }
    }

    func restore() async {
        guard Self.isStoreBuild, !isPurchasing else { return }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refresh()
            message = canCall ? String(localized: "购买状态已恢复。")
                : String(localized: "已检查当前 Apple 账户的购买记录，暂未找到有效的通话权益。")
        } catch { message = String(localized: "恢复购买未能完成，请检查网络与 Apple 账户后重试。") }
    }
}
