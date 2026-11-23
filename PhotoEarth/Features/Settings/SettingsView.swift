import SwiftUI

extension EnvironmentValues {
    @Entry var leavePurchaseSample: (() -> Void)? = nil
}

struct SettingsView: View {
    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.leavePurchaseSample) private var leavePurchaseSample
    @State private var showingPurchase = false
    private enum FocusedControl: Hashable { case update, complete, rebuild, journeyMinimum }
    @ObservedObject var model: AppModel
    @ObservedObject private var analytics = ProductAnalytics.shared
    @FocusState private var focusedControl: FocusedControl?
    @State private var returnScanAction: FocusedControl?
    @State private var showsScanDetails = false
    @State private var homeScreenUpdateFailed = false
    @State private var showsJourneyMinimum = false
    @State private var journeyMinimumText = ""
    @AppStorage("photoEarth.showsGlobeHints") private var showsGlobeHints = true
    @AppStorage("photoEarth.waitsForInitialGlobeRender") private var waitsForInitialGlobeRender = false

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 56) {
                photoSettings
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .focusSection()

                VStack(alignment: .leading, spacing: 32) {
                    homeScreenSettings
                    globeSettings
                    if case .trial(let end) = purchases.access {
                        VStack(alignment: .leading, spacing: 15) {
                            caption(AppLocalization.format("purchase.until", defaultValue: "Trial ends %@.", end.formatted(date: .long, time: .shortened)))
                            Button(String(localized: "purchase.full")) { showingPurchase = true }
                                .buttonStyle(.glass).accessibilityIdentifier("settings-purchase")
                        }
                    } else if purchases.access == .unlocked {
                        caption(String(localized: "purchase.owned"))
                    }
                    if analytics.isConfigured {
                        VStack(alignment: .leading, spacing: 20) {
                            settingSwitch(AppLocalization.string("settings.usage_analytics", defaultValue: "Share Usage Analytics"),
                                          isOn: Binding(get: { analytics.enabled }, set: analytics.setEnabled),
                                          identifier: "settings-usage-analytics")
                            caption(AppLocalization.string("settings.usage_analytics_help", defaultValue: "Send PostHog an installation ID and actions such as opening a photo wall or starting a slideshow. Photos and locations stay private."))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.top, 100)
            .padding(.bottom, 80)
        }
        .background(Color(red: 0.012, green: 0.022, blue: 0.037).ignoresSafeArea())
        .accessibilityIdentifier("app-settings")
        .sheet(isPresented: $showsJourneyMinimum, onDismiss: { focusedControl = .journeyMinimum }) { journeyMinimumEditor }
        .sheet(isPresented: $showingPurchase) { PurchaseOffers(store: purchases) }
        .task(id: model.isPreparationPresented) {
            guard !model.isPreparationPresented, let action = returnScanAction else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, model.phase == .globe else { return }
            focusedControl = action == .complete && incompletePlaceCount == 0 ? .update : action
            returnScanAction = nil
        }
    }

    private var photoSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(AppLocalization.string("settings.photos_and_scan", defaultValue: "Photos & Scanning"))
            Text(model.isUsingSampleData
                 ? AppLocalization.string("settings.sample_source", defaultValue: "Exploring a sample journey")
                 : AppLocalization.string("settings.library_source", defaultValue: "From your photo library"))
                .font(.system(size: 26))
            if let index = model.index {
                Text(AppLocalization.format("settings.index_summary", defaultValue: "%1$@ · %2$@",
                                            AppLocalization.itemCount(index.visiblePhotoCount),
                                            AppLocalization.placeCount(index.places.count)))
                    .font(.system(size: 23)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-index-summary")
            }
            if model.usesLivePhotoLibrary {
                Button(AppLocalization.string("scan.scope.title", defaultValue: "Scan Scope"), systemImage: "photo.on.rectangle.angled") {
                    model.showScanScope()
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings-scan-scope")
            }
            Button(model.isUsingSampleData
                   ? AppLocalization.string("settings.connect_photos", defaultValue: "Connect My Photos")
                   : AppLocalization.string("settings.update", defaultValue: "Update Photos & Places"),
                   systemImage: model.isUsingSampleData ? "photo.on.rectangle" : "arrow.clockwise") {
                if let leavePurchaseSample { leavePurchaseSample(); return }
                returnScanAction = .update
                Task { await model.updateLibrary() }
            }
            .buttonStyle(.glass)
            .focused($focusedControl, equals: .update)
            .accessibilityIdentifier("settings-scan")
            if model.sampleConnectionDenied {
                caption(AppLocalization.string("permission.message", defaultValue: "In Settings > General > Privacy & Security > Photos, allow Photo Earth to access your photos."))
            }

            if model.supportsTransitFiltering {
                settingSwitch(
                    AppLocalization.string("settings.hide_transit", defaultValue: "Hide Likely Transit Photos"),
                    isOn: Binding(get: { model.hidesTransitPhotos }, set: { enabled in
                        Task { await model.setHidesTransitPhotos(enabled) }
                    }), identifier: "settings-hide-transit"
                )
                caption(AppLocalization.string("settings.transit_help", defaultValue: "Hide brief stops and photos taken in transit. Favorites stay visible."))
                if model.hidesTransitPhotos, let index = model.index {
                    Text(AppLocalization.format("settings.transit_count", defaultValue: "%lld items hidden",
                                                Int64(index.hiddenTransitPhotoCount)))
                        .font(.system(size: 23)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-transit-count")
                }
                if let error = model.transitFilterError { caption(error) }
            }

            Button {
                journeyMinimumText = String(model.minimumJourneyItems)
                showsJourneyMinimum = true
            } label: {
                Label {
                    HStack(spacing: 18) {
                        Text(journeyMinimumTitle)
                        Text(AppLocalization.number(model.minimumJourneyItems))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "number")
                }
            }
            .buttonStyle(.glass)
            .focused($focusedControl, equals: .journeyMinimum)
            .accessibilityLabel(journeyMinimumTitle)
            .accessibilityValue(AppLocalization.number(model.minimumJourneyItems))
            .accessibilityIdentifier("settings-journey-minimum")

            if !model.isUsingSampleData, let index = model.index {
                Button {
                    showsScanDetails.toggle()
                } label: {
                    Label(AppLocalization.string("settings.scan_details", defaultValue: "Scan Details"),
                          systemImage: showsScanDetails ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.glass)
                .accessibilityValue(showsScanDetails
                    ? AppLocalization.string("settings.expanded", defaultValue: "Expanded")
                    : AppLocalization.string("settings.collapsed", defaultValue: "Collapsed"))
                .accessibilityIdentifier("settings-scan-details")
                if showsScanDetails { scanDetails(index) }
            }
        }
    }

    private var journeyMinimumTitle: String {
        AppLocalization.string("journey.minimum.title", defaultValue: "Minimum Items per Visit")
    }

    private var journeyMinimumEditor: some View {
        let range = JourneyVisitThreshold.range
        let draft = journeyMinimumText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Int(draft).flatMap { range.contains($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 32) {
            Text(journeyMinimumTitle).font(.system(size: 52, weight: .light))
            caption(AppLocalization.string("journey.minimum.note", defaultValue: "Count photos and videos with a location for each visit. This minimum applies to Home, Recently Visited, and the Apple TV Home Screen."))
            HStack(spacing: TVControlLayout.actionSpacing) {
                ForEach(JourneyVisitThreshold.presets, id: \.self) { count in
                    Button(AppLocalization.number(count)) { journeyMinimumText = String(count) }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("settings-journey-minimum-preset-\(count)")
                }
            }
            .focusSection()
            let rangeText = AppLocalization.format("journey.minimum.range", defaultValue: "%1$@–%2$@",
                                                   AppLocalization.number(range.lowerBound), AppLocalization.number(range.upperBound))
            HStack(spacing: 20) {
                TextField(AppLocalization.string("journey.minimum.custom", defaultValue: "Custom Number"), text: $journeyMinimumText)
                    .keyboardType(.numberPad)
                    .frame(width: 320)
                    .accessibilityHint(rangeText)
                    .accessibilityIdentifier("settings-journey-minimum-custom")
                Text(rangeText).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Button(AppLocalization.string("common.save", defaultValue: "Save")) {
                guard let value else { return }
                model.setMinimumJourneyItems(value)
                showsJourneyMinimum = false
            }
            .buttonStyle(.glassProminent)
            .disabled(value == nil)
            .accessibilityIdentifier("settings-journey-minimum-save")
        }
        .padding(96)
        .frame(maxWidth: 1120)
    }

    @ViewBuilder private func scanDetails(_ index: TravelIndex) -> some View {
        caption(AppLocalization.string("settings.privacy_message", defaultValue: "Photo Earth reads capture dates, locations, and camera information on this Apple TV. You can exclude albums from the scan. Your original photos and videos stay unchanged."))
        caption(AppLocalization.format("settings.last_organized", defaultValue: "Last organized %@",
                                       dateString(index.generatedAt)))
        if let check = model.lastLibraryCheck {
            caption(AppLocalization.format("settings.last_checked", defaultValue: "Photos checked %@", dateString(check)))
        }
        let missing = incompletePlaceCount
        caption(AppLocalization.format("settings.label_summary", defaultValue: "Named places %1$@ / %2$@",
                                       AppLocalization.number(index.places.count - missing),
                                       AppLocalization.number(index.places.count)))
        if missing > 0 {
            Button(AppLocalization.string("settings.complete_places", defaultValue: "Complete Place Names")) {
                returnScanAction = .complete
                Task { await model.updateLibrary(.labels) }
            }
            .buttonStyle(.glass)
            .focused($focusedControl, equals: .complete)
            .accessibilityIdentifier("settings-complete-places")
        }
        Button(AppLocalization.string("settings.rebuild", defaultValue: "Rescan Photos and Videos")) {
            returnScanAction = .rebuild
            Task { await model.updateLibrary(.rebuild) }
        }
        .buttonStyle(.glass)
        .focused($focusedControl, equals: .rebuild)
        .accessibilityIdentifier("settings-rebuild")
        caption(AppLocalization.string("settings.rebuild_message", defaultValue: "Recheck all media information while keeping valid place names. Saved memories remain available during the update."))
    }

    private var homeScreenSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(AppLocalization.string("settings.home_screen", defaultValue: "Apple TV Home Screen"))
            settingSwitch(
                AppLocalization.string("settings.journeys_on_home", defaultValue: "Show Recently Visited Cities"),
                isOn: Binding(get: { model.showsJourneysOnTopShelf }, set: { enabled in
                    model.setShowsJourneysOnTopShelf(enabled)
                    homeScreenUpdateFailed = model.showsJourneysOnTopShelf != enabled
                }),
                identifier: "settings-top-shelf"
            )
            if homeScreenUpdateFailed {
                caption(AppLocalization.string("settings.transit_error", defaultValue: "Couldn’t update this setting. Please try again."))
            }
            caption(AppLocalization.string("settings.home_screen_help", defaultValue: "Place Photo Earth in the top row, then highlight its icon to see cities with cover photos."))
        }
    }

    private var globeSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(AppLocalization.string("settings.globe_controls", defaultValue: "Globe Controls"))
            settingSwitch(AppLocalization.string("settings.show_hints", defaultValue: "Show Globe Control Hints"),
                          isOn: Binding(get: { showsGlobeHints }, set: { enabled in
                              showsGlobeHints = enabled
                              ProductAnalytics.shared.capture(.settingsChanged, value: "globe_hints")
                          }), identifier: "settings-globe-hints")
            settingSwitch(AppLocalization.string("settings.wait_for_globe", defaultValue: "Wait for Globe Imagery (Experimental)"),
                          isOn: Binding(get: { waitsForInitialGlobeRender }, set: { enabled in
                              waitsForInitialGlobeRender = enabled
                              ProductAnalytics.shared.capture(.settingsChanged, value: "globe_imagery")
                          }), identifier: "settings-wait-for-globe")
        }
    }

    private func settingSwitch(_ title: String, isOn: Binding<Bool>, identifier: String) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 27))
            .accessibilityValue(isOn.wrappedValue
                ? AppLocalization.string("state.on", defaultValue: "On")
                : AppLocalization.string("state.off", defaultValue: "Off"))
            .accessibilityIdentifier(identifier)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 32, weight: .medium))
            .accessibilityAddTraits(.isHeader)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 23)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().locale(AppLocalization.locale))
    }

    private var incompletePlaceCount: Int {
        model.index?.places.filter { !PlaceDisplayLabel(place: $0).isComplete }.count ?? 0
    }
}
