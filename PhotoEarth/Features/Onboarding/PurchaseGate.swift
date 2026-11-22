import SwiftUI
import StoreKit

struct PurchaseGate: View {
    @StateObject private var store = PurchaseStore()
    @Environment(\.scenePhase) private var phase
    @State private var showingSample = false
    @State private var incomingURL: URL?

    var body: some View {
        Group {
            if store.access.permitsLibrary {
                ContentView(incomingURL: $incomingURL)
            } else if store.access == .checking {
                ScanningView()
            } else {
                PurchaseOffers(store: store, sample: { showingSample = true })
                    .sheet(isPresented: $showingSample) {
                        ContentView(sampleOnly: true, leaveSample: { showingSample = false })
                    }
            }
        }
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .task { await store.start() }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active { Task { await store.refreshAccess() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await store.refreshAccess() }
        }
        .onOpenURL { url in
            showingSample = false
            incomingURL = url
        }
    }
}

struct PurchaseOffers: View {
    @ObservedObject var store: PurchaseStore
    var sample: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var action: Action?
    private enum Action { case trial, buy, restore, retry, sample }
    private var full: Product? { store.products[PurchaseStore.lifetimeID] }
    private var canStartTrial: Bool {
        store.access == .available && store.products[PurchaseStore.trialID]?.price == 0 && full != nil
    }

    var body: some View {
        ZStack {
            SpaceBackdrop()
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.system(size: 58, weight: .semibold))
                Text(detail).font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("purchase-terms")
                VStack(alignment: .leading, spacing: 15) {
                    if canStartTrial {
                        Button(String(localized: "purchase.trial")) { Task { await store.purchase(PurchaseStore.trialID) } }
                            .focused($action, equals: .trial).accessibilityIdentifier("purchase-trial")
                    }
                    if let full, store.access != .unverified {
                        Button(AppLocalization.format("purchase.buy", defaultValue: "Unlock for %@", full.displayPrice)) {
                            Task { await store.purchase(PurchaseStore.lifetimeID) }
                        }
                        .focused($action, equals: .buy).accessibilityIdentifier("purchase-buy")
                    }
                    Button(String(localized: "purchase.restore")) { Task { await store.restore() } }
                        .focused($action, equals: .restore).accessibilityIdentifier("purchase-restore")
                    if full == nil || store.access == .unverified || (store.access == .available && !canStartTrial) {
                        Button(String(localized: "common.retry")) {
                            Task { await store.refreshAccess(); await store.loadProducts() }
                        }.focused($action, equals: .retry)
                    }
                    if let sample {
                        Button(AppLocalization.string("sample.view_first", defaultValue: "Explore a Sample Journey"), action: sample)
                            .focused($action, equals: .sample).accessibilityIdentifier("purchase-sample")
                    }
                }
                .buttonStyle(.glass)
                .disabled(store.busy)
                if store.busy { ProgressView() }
                if let notice = store.notice {
                    Text(noticeText(notice)).font(.callout).accessibilityIdentifier("purchase-notice")
                }
            }
            .frame(maxWidth: 970, alignment: .leading).padding(65)
        }
        .task(id: canStartTrial) {
            if action == nil || action == .restore {
                action = canStartTrial ? .trial : (full != nil && store.access != .unverified ? .buy : .restore)
            }
        }
        .onChange(of: store.access) { _, value in
            if value == .unlocked, sample == nil { dismiss() }
        }
    }

    private var title: String {
        switch store.access {
        case .expired: String(localized: "purchase.expired")
        case .unverified: String(localized: "purchase.verify")
        default: String(localized: "purchase.title")
        }
    }

    private var detail: String {
        if store.access == .unverified { return String(localized: "purchase.verificationHelp") }
        guard let full else { return String(localized: "purchase.unavailable") }
        if case .trial(let end) = store.access {
            return AppLocalization.format("purchase.until", defaultValue: "Trial ends %@.", end.formatted(date: .long, time: .shortened))
        }
        if store.access == .expired {
            return AppLocalization.format("purchase.after", defaultValue: "Unlock your personal globe, journeys and slideshows with one payment of %@.", full.displayPrice)
        }
        return AppLocalization.format("purchase.terms", defaultValue: "Explore your photos for seven days. After that, a one-time purchase of %@ unlocks your globe, journeys and slideshows. No automatic charge.", full.displayPrice)
    }

    private func noticeText(_ notice: PurchaseStore.Notice) -> String {
        switch notice {
        case .pending: String(localized: "purchase.pending")
        case .failed: String(localized: "purchase.failed")
        case .nothingToRestore: String(localized: "purchase.noActive")
        }
    }
}
