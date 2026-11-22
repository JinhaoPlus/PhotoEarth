//
//  ContentView.swift
//  PhotoEarth
//
//  Created by doupi on 2026/9/4.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model: AppModel
    @State private var reportedForeground = false
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var purchases: PurchaseStore
    @Binding var incomingURL: URL?
    let sampleOnly: Bool
    let leaveSample: (() -> Void)?

    init(incomingURL: Binding<URL?> = .constant(nil), sampleOnly: Bool = false, leaveSample: (() -> Void)? = nil) {
        _incomingURL = incomingURL
        self.sampleOnly = sampleOnly
        self.leaveSample = leaveSample
        _model = StateObject(wrappedValue: AppModel(sampleOnly: sampleOnly))
    }

    private var globeAcceptsInput: Bool { model.phase == .globe || model.phase == .scanning || model.isExploringPublicGlobe }

    var body: some View {
        ZStack {
            // The map/camera host survives authorization, preparation, home,
            // and exploration. Phase changes replace only the foreground UI.
            GlobeView(model: model)
                .id(model.scanScopeRevision)
                .accessibilityElement(children: .contain)
                .opacity(globeAcceptsInput || model.phase == .welcome ? 1 : 0)
                .disabled(!globeAcceptsInput)
                .allowsHitTesting(globeAcceptsInput)
                .accessibilityHidden(!globeAcceptsInput)
            switch model.isExploringPublicGlobe ? .globe : model.phase {
            case .loading:
                ScanningView()
            case .welcome:
                if model.canBrowsePreparedLibrary {
                    MessageView(symbol: "globe.asia.australia",
                                title: AppLocalization.string("ready.title", defaultValue: "Your Travel Globe Is Ready"),
                                message: AppLocalization.string("ready.message", defaultValue: "Remaining place names will continue updating."),
                                primaryTitle: AppLocalization.string("ready.enter", defaultValue: "Enter My Globe"), primaryAction: model.closePreparation,
                                secondaryTitle: AppLocalization.string("ready.progress", defaultValue: "View Preparation Progress"), secondaryAction: model.showPreparation)
                } else if model.canReturnToPreparation {
                    MessageView(symbol: "photo.on.rectangle",
                                title: model.preparationProgress.title, message: model.preparationProgress.countText,
                                primaryTitle: AppLocalization.string("ready.progress", defaultValue: "View Preparation Progress"), primaryAction: model.showPreparation,
                                secondaryTitle: AppLocalization.string("sample.view", defaultValue: "View Sample Journey"), secondaryAction: model.useSampleData)
                } else {
                    WelcomeView(begin: { Task { await model.requestAccessAndScan() } }, showDemo: model.useSampleData)
                        .onAppear { ProductAnalytics.shared.capture(.welcomePresented) }
                }
            case .scanning:
                EmptyView()
            case .globe:
                EmptyView()
            case .empty:
                MessageView(
                    symbol: "location.slash",
                    title: AppLocalization.string("empty_library.title", defaultValue: "No Travel Photos Found"),
                    message: AppLocalization.string("empty_library.message", defaultValue: "Check the albums included in your scan and the location information in Photos."),
                    primaryTitle: AppLocalization.string("sample.view", defaultValue: "View Sample Journey"),
                    primaryAction: model.useSampleData,
                    secondaryTitle: model.usesLivePhotoLibrary ? AppLocalization.string("scan.scope.title", defaultValue: "Scan Scope") : AppLocalization.string("library.rescan", defaultValue: "Scan Again"),
                    secondaryAction: {
                        if model.usesLivePhotoLibrary { model.showScanScope() }
                        else { Task { await model.rescan() } }
                    }
                )
            case .denied:
                MessageView(
                    symbol: "lock.shield",
                    title: AppLocalization.string("permission.title", defaultValue: "Photo Access Required"),
                    message: AppLocalization.string("permission.message", defaultValue: "In Settings > General > Privacy & Security > Photos, allow Photo Earth to access your photos."),
                    primaryTitle: AppLocalization.string("sample.view", defaultValue: "View Sample Journey"),
                    primaryAction: model.useSampleData,
                    secondaryTitle: nil,
                    secondaryAction: nil
                )
            case .failed(let message):
                MessageView(
                    symbol: "exclamationmark.triangle",
                    title: AppLocalization.string("generation.failed", defaultValue: "Couldn't Build the Travel Globe"),
                    message: message,
                    primaryTitle: AppLocalization.string("common.retry", defaultValue: "Try Again"),
                    primaryAction: { Task { await model.rescan() } },
                    secondaryTitle: AppLocalization.string("sample.view", defaultValue: "View Sample Journey"),
                    secondaryAction: model.useSampleData
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .sheet(item: Binding(get: { model.isExploringPublicGlobe ? nil : model.scanScope }, set: { value in
            if value == nil, !model.isExploringPublicGlobe { model.cancelScanScope() }
        })) { presentation in
            TravelScanScopeView(model: model, presentation: presentation)
        }
        .environment(\.leavePurchaseSample, leaveSample)
        .onChange(of: incomingURL, initial: true) { _, url in
            guard let url, !sampleOnly else { return }
            model.requestTopShelfURL(url)
            incomingURL = nil
        }
        .task {
            if sampleOnly { model.useSampleData() }
            else { await model.start() }
        }
        .onDisappear {
            if sampleOnly || !purchases.access.permitsLibrary { model.closeLibrarySession() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { reportedForeground = false }
            if phase == .active, !reportedForeground {
                reportedForeground = true
                ProductAnalytics.shared.capture(.foregrounded)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if !sampleOnly { Task { await model.setSceneActive(phase == .active) } }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    PurchaseGate()
}
