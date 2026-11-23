import SwiftUI
import StoreKit

struct PurchaseGate: View {
    @StateObject private var store = PurchaseStore()
    @Environment(\.scenePhase) private var phase
    @State private var incomingURL: URL?

    var body: some View {
        Group {
            if store.access == .checking {
                ScanningView()
            } else {
                ContentView(incomingURL: $incomingURL)
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
            incomingURL = url
        }
    }
}

struct PurchaseOffers: View {
    @ObservedObject var store: PurchaseStore
    var requestedTitle: String?
    @Environment(\.dismiss) private var dismiss
    enum Action: Hashable { case trial, buy, restore, retry, back }
    var settingsFocus: FocusState<Action?>.Binding?
    @FocusState private var sheetFocus: Action?
    private var focus: FocusState<Action?>.Binding { settingsFocus ?? $sheetFocus }
    private var inSettings: Bool { settingsFocus != nil }

    static func firstSettingsAction(for store: PurchaseStore) -> Action {
        if store.access == .unverified { return .restore }
        return store.products[PurchaseStore.lifetimeID] == nil ? .retry : .buy
    }
    private var full: Product? { store.products[PurchaseStore.lifetimeID] }
    private var canStartTrial: Bool {
        store.access == .available && store.products[PurchaseStore.trialID]?.price == 0 && full != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(inSettings ? .title2.weight(.semibold) : .system(size: 50, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("purchase-heading")
                    if case .trial(let end) = store.access {
                        Text(AppLocalization.format("purchase.until", defaultValue: "Trial ends %@.",
                                                    end.formatted(.dateTime.year().month(.wide).day().hour().minute().locale(AppLocalization.locale))))
                            .accessibilityIdentifier("purchase-trial-end")
                    }
                    Text(detail).foregroundStyle(.secondary)
                        .accessibilityIdentifier("purchase-terms")
                }
                .font(.system(size: 30))
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 18) {
                    Group {
                        if inSettings {
                            VStack(alignment: .leading, spacing: 16) { primaryButtons }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 24) { primaryButtons }.fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 16) { primaryButtons }
                            }
                        }
                    }
                    .font(.system(size: 32, weight: .medium))
                    if let trialNote {
                        Text(trialNote)
                            .font(.system(size: 26)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("purchase-trial-terms")
                    }
                }

                HStack(spacing: 24) {
                    if !inSettings { returnButton }
                    Button { Task { await store.restore() } } label: {
                        actionLabel(String(localized: "purchase.restore"))
                    }
                        .focused(focus, equals: .restore).accessibilityIdentifier("purchase-restore")
                }
                .font(.system(size: 26))

                if store.busy { ProgressView() }
                if let notice = store.notice {
                    Text(noticeText(notice)).font(.callout).accessibilityIdentifier("purchase-notice")
                }
            }
            .buttonStyle(.glass)
            .disabled(store.busy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inSettings ? 20 : 64).padding(.vertical, inSettings ? 10 : 54)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: canStartTrial) {
            guard !inSettings else { return }
            if sheetFocus == nil || sheetFocus == .restore {
                sheetFocus = canStartTrial && requestedTitle != nil ? .trial : (full != nil && store.access != .unverified ? .buy : .restore)
            }
        }
        .onChange(of: store.access) { _, value in
            guard !inSettings else { return }
            if value == .unlocked || (requestedTitle != nil && value.permitsLibrary) { dismiss() }
        }
    }

    @ViewBuilder private func actionLabel(_ text: String) -> some View {
        if inSettings {
            Text(text).frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
        } else {
            Text(text)
        }
    }

    @ViewBuilder private var primaryButtons: some View {
        if canStartTrial {
            Button { Task { await purchase(PurchaseStore.trialID) } } label: {
                actionLabel(String(localized: "purchase.trial"))
            }
                .focused(focus, equals: .trial).accessibilityIdentifier("purchase-trial")
        }
        if let full, store.access != .unverified {
            Button { Task { await purchase(PurchaseStore.lifetimeID) } } label: {
                actionLabel(AppLocalization.format("purchase.full", defaultValue: "Buy Full Version · %@ (one time)", full.displayPrice))
            }
                .focused(focus, equals: .buy).accessibilityIdentifier("purchase-buy")
        }
        if full == nil || store.access == .unverified || (store.access == .available && !canStartTrial) {
            Button {
                Task { await store.refreshAccess(); await store.loadProducts() }
            } label: {
                actionLabel(String(localized: "common.retry"))
            }.focused(focus, equals: .retry).accessibilityIdentifier("purchase-retry")
        }
    }

    private func purchase(_ id: String) async {
        if await store.purchase(id) == .cancelled, !inSettings { dismiss() }
    }

    private var returnButton: some View {
        Button(requestedTitle == nil ? String(localized: "preview.back") : String(localized: "purchase.later")) {
            dismiss()
        }
        .focused(focus, equals: .back).accessibilityIdentifier("purchase-back")
    }

    private var title: String {
        if let requestedTitle { return requestedTitle }
        return switch store.access {
        case .expired: String(localized: "purchase.expired")
        case .unverified: String(localized: "purchase.verify")
        case .trial: String(localized: "purchase.trial_active")
        default: String(localized: "settings.unlock_full_version")
        }
    }

    private var detail: String {
        if store.access == .unverified { return String(localized: "purchase.verificationHelp") }
        guard full != nil else { return String(localized: "purchase.unavailable") }
        return String(localized: "settings.unlock_help")
    }

    private var trialNote: String? {
        switch store.access {
        case .available where canStartTrial, .trial: String(localized: "purchase.trial_end_terms")
        case .expired: requestedTitle == nil ? String(localized: "purchase.free_after_trial") : String(localized: "purchase.playbackEnded")
        default: nil
        }
    }

    private func noticeText(_ notice: PurchaseStore.Notice) -> String {
        switch notice {
        case .pending: String(localized: "purchase.pending")
        case .failed: String(localized: "purchase.failed")
        case .nothingToRestore: String(localized: "purchase.noActive")
        }
    }
}
