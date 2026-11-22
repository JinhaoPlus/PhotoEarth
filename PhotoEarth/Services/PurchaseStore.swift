import Combine
import StoreKit
import TVServices

@MainActor
final class PurchaseStore: ObservableObject {
    static let trialID = "com.doupi.PhotoEarth.PhotoEarth.trial7days"
    static let lifetimeID = "com.doupi.PhotoEarth.PhotoEarth.lifetime"
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    enum Access: Equatable {
        case checking, available, expired, unlocked, unverified
        case trial(until: Date)

        var permitsLibrary: Bool {
            switch self {
            case .trial, .unlocked: true
            default: false
            }
        }
    }

    enum Notice { case pending, failed, nothingToRestore }
    @Published private(set) var access = Access.checking
    @Published private(set) var products = [String: Product]()
    @Published private(set) var busy = false
    @Published private(set) var notice: Notice?
    private var revision = 0
    private var expiration: Task<Void, Never>?
    private var listener: Task<Void, Never>?

    private var now: Date {
#if DEBUG && targetEnvironment(simulator)
        if let offset = ProcessInfo.processInfo.environment["PHOTOEARTH_STORE_CLOCK_OFFSET"].flatMap(Double.init) {
            return Date.now.addingTimeInterval(offset)
        }
#endif
        return .now
    }

    func start() async {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.refreshAccess()
                if case .verified(let transaction) = result, self.recognizes(transaction.productID) {
                    await transaction.finish()
                }
            }
        }
        await refreshAccess()
        await loadProducts()
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: [Self.trialID, Self.lifetimeID])
            if notice == .failed { notice = nil }
            products = Dictionary(uniqueKeysWithValues: fetched.filter { $0.type == .nonConsumable }.map { ($0.id, $0) })
        } catch {
            // A temporary catalog failure doesn't invalidate a verified purchase.
            if products.isEmpty { notice = .failed }
        }
    }

    private func recognizes(_ id: String) -> Bool { id == Self.trialID || id == Self.lifetimeID }

    func refreshAccess() async {
#if DEBUG
        if ProcessInfo.processInfo.environment["PHOTOEARTH_UI_OWNED_FIXTURE"] == "1" {
            apply(.unlocked)
            return
        }
#endif
        revision += 1
        let ticket = revision
        var trialEnd: Date?
        var ownsFullVersion = false
        var unverifiable = false
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let tx) where tx.revocationDate == nil:
                if tx.productID == Self.lifetimeID { ownsFullVersion = true }
                if tx.productID == Self.trialID {
                    let end = tx.originalPurchaseDate.addingTimeInterval(Self.trialDuration)
                    trialEnd = min(trialEnd ?? end, end)
                }
            case .unverified(let tx, _) where recognizes(tx.productID): unverifiable = true
            default: break
            }
        }
        guard ticket == revision else { return }
        if ownsFullVersion { apply(.unlocked) }
        else if let trialEnd, now < trialEnd { apply(.trial(until: trialEnd)) }
        else if unverifiable { apply(.unverified) }
        else { apply(trialEnd == nil ? .available : .expired) }
    }

    private func apply(_ value: Access) {
        if access != value {
            let until: Date?
            switch value {
            case .trial(let end): until = end
            case .unlocked: until = .distantFuture
            default: until = nil
            }
            JourneyShelfKeychain.setPurchaseAccess(until: until)
            TVTopShelfContentProvider.topShelfContentDidChange()
            access = value
        }
        expiration?.cancel()
        guard case .trial(let end) = value else { return }
        let remaining = max(0, end.timeIntervalSince(now))
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            // Recheck the wall clock, including after sleep or a clock adjustment.
            guard let self, self.access == value else { return }
            if self.now >= end { self.apply(.expired) }
            else { await self.refreshAccess() }
        }
    }

    func purchase(_ id: String) async {
        guard !busy, let product = products[id] else { return }
        guard id != Self.trialID || (access == .available && product.price == 0 && products[Self.lifetimeID] != nil) else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let tx)) where tx.productID == id:
                await refreshAccess()
                await tx.finish()
            case .pending: notice = .pending
            case .userCancelled: break
            default: notice = .failed
            }
        } catch { notice = .failed }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshAccess()
            if !access.permitsLibrary { notice = .nothingToRestore }
        } catch { notice = .failed }
    }
}
