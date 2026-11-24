import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var purchases: PurchaseStore
    @State private var showsPurchaseDetail = false
    @FocusState private var offerAction: PurchaseOffers.Action?
    @State private var reference: SettingsReference?
    @AppStorage(SlideshowMusicController.automaticMusicOffKey) private var automaticMusicOff = false
    private enum Category: String, CaseIterable {
        case photos, globe, music, home, privacy

        var symbol: String {
            switch self {
            case .photos: "photo.on.rectangle"
            case .globe: "globe"
            case .home: "tv"
            case .music: "music.note.list"
            case .privacy: "hand.raised"
            }
        }

        var title: String {
            switch self {
            case .photos: AppLocalization.string("settings.photos_and_scan", defaultValue: "Photos & Scanning")
            case .globe: AppLocalization.string("settings.globe_controls", defaultValue: "Globe Controls")
            case .home: AppLocalization.string("settings.home_screen", defaultValue: "Apple TV Home Screen")
            case .music: String(localized: "slideshow.music.control_title")
            case .privacy: String(localized: "settings.privacy")
            }
        }
    }

    private enum FocusedControl: Hashable {
        case category(Category), scope, update, complete, rebuild, journeyMinimum, scanDetails
        case transit, hints, imagery, home, purchase, privacy, policy, automaticMusic, credits
    }
    @State private var category: Category = .photos
    @ObservedObject var model: AppModel
    @ObservedObject private var analytics = ProductAnalytics.shared
    @FocusState private var focusedControl: FocusedControl?
    @State private var returnScanAction: FocusedControl?
    @State private var showsScanDetails = false
    @State private var homeScreenUpdateFailed = false
    @State private var showsJourneyMinimum = false
    @State private var journeyMinimumText = ""
    @AppStorage("photoEarth.showsGlobeHints") private var showsGlobeHints = true
    @AppStorage("photoEarth.waitsForInitialGlobeRender") private var waitsForInitialGlobeRender = true

    var body: some View {
        HStack(alignment: .top, spacing: 104) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Category.allCases, id: \.self) { item in
                    Button {
                        category = item
                        focusedControl = firstControl
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 30, weight: .medium))
                                .frame(width: 40)
                                .accessibilityHidden(true)
                            Text(item.title)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.forward").font(.callout).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                    .background {
                        if !showsPurchaseDetail && category == item && focusedControl != .category(item) {
                            Capsule().fill(.primary.opacity(0.15))
                        }
                    }
                    .focused($focusedControl, equals: .category(item))
                    .accessibilityAddTraits(!showsPurchaseDetail && item == category ? .isSelected : [])
                    .accessibilityIdentifier("settings-category-\(item.rawValue)")
                }

                Spacer(minLength: 40)
                fullVersionFooter
            }
            .padding(.bottom, 48)
            .frame(width: 520)
            .focusSection()

            Group {
                if showsPurchaseDetail {
                    PurchaseOffers(store: purchases, origin: .settings, settingsFocus: $offerAction)
                } else {
                    categoryDetails
                }
            }
            .focusSection()
            .onExitCommand { focusedControl = showsPurchaseDetail ? .purchase : .category(category) }
        }
        .padding(.horizontal, 110).padding(.top, 120)
        .background(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.065)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .onChange(of: focusedControl) { previous, current in
            if current == .purchase {
                if !showsPurchaseDetail { purchases.clearNotice() }
                showsPurchaseDetail = true
            } else if case .category(let item) = current {
                if previous == .purchase {
                    showsPurchaseDetail = false
                    category = item
                } else if showsPurchaseDetail {
                    focusedControl = .purchase
                } else if let previous, case .category = previous { category = item }
                else if previous != nil && item != category { focusedControl = .category(category) }
                else { category = item }
            } else if case .category(.globe) = previous, current != nil, current != firstControl {
                focusedControl = firstControl
            }
        }
        .sheet(isPresented: $showsJourneyMinimum, onDismiss: { focusedControl = .journeyMinimum }) { journeyMinimumEditor }
        .onChange(of: offerAction) { previous, current in
            if showsPurchaseDetail, previous == nil, current != nil {
                offerAction = PurchaseOffers.firstSettingsAction(for: purchases)
            }
        }
        .onChange(of: purchases.access) { _, access in
            guard showsPurchaseDetail else { return }
            if access == .unlocked {
                showsPurchaseDetail = false
                focusedControl = .category(category)
            } else if case .trial = access {
                focusedControl = .purchase
            }
        }
        .sheet(item: $reference, onDismiss: { focusedControl = category == .music ? .credits : .policy }) { item in
            SettingsReferenceView(reference: item)
                .onAppear { analytics.capture(.settingsOpenedReference, value: item.rawValue) }
        }
        .task(id: model.isPreparationPresented) {
            guard !model.isPreparationPresented, let action = returnScanAction else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, model.phase == .globe else { return }
            focusedControl = action == .complete && !model.preparationProgress.canContinuePlaceNames ? .update : action
            returnScanAction = nil
        }
    }

    private var categoryDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(category.title).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                switch category {
                case .photos: photoSettings
                case .globe: globeSettings
                case .home: homeScreenSettings
                case .music: musicSettings
                case .privacy:
                    actionRow(String(localized: "settings.policy")) { reference = .privacy }
                        .focused($focusedControl, equals: .policy)
                        .accessibilityIdentifier("settings-policy")
                    settingSwitch(AppLocalization.string("settings.usage_analytics", defaultValue: "Share Usage Analytics"),
                                  isOn: Binding(get: { analytics.enabled }, set: { analytics.setEnabled($0) }),
                                  identifier: "settings-usage-analytics")
                        .focused($focusedControl, equals: .privacy)
                    VStack(alignment: .leading, spacing: 8) {
                        caption(String(localized: "settings.analytics.purpose"))
                            .accessibilityIdentifier("settings-analytics-purpose")
                        caption(analytics.isConfigured
                            ? String(localized: "settings.usage_analytics_help")
                            : String(localized: "settings.analytics.inactive"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 10).padding(.bottom, 60)
        }
        .id(category)
        .scrollClipDisabled()
    }

    private var firstControl: FocusedControl {
        switch category {
        case .photos: model.usesLivePhotoLibrary ? .scope : .update
        case .globe: .hints
        case .home: .home
        case .music: .automaticMusic
        case .privacy: .policy
        }
    }

    private func actionRow(_ title: String, value: String? = nil, symbol: String = "chevron.forward",
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                Spacer()
                if let value { Text(value).monospacedDigit().foregroundStyle(.secondary) }
                Image(systemName: symbol).font(.callout).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
        }
        .font(.system(size: 29))
        .buttonStyle(.glass)
    }

    private var musicSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingSwitch(String(localized: "settings.music.automatic"),
                          isOn: Binding(get: { !automaticMusicOff }, set: { enabled in
                              automaticMusicOff = !enabled
                              analytics.capture(.settingsChanged, value: "automatic_music")
                          }),
                          identifier: "settings-music-automatic")
                .focused($focusedControl, equals: .automaticMusic)
            caption(String(localized: "settings.music.automatic_help"))
            Text(String(localized: "slideshow.music.online")).font(.headline)
            caption(String(localized: "settings.music.online_help"))
            actionRow(String(localized: "settings.music.credits")) { reference = .credits }
                .focused($focusedControl, equals: .credits)
                .accessibilityIdentifier("settings-music-credits")
            Text(verbatim: "Apple Music").font(.headline)
            caption(String(localized: "settings.music.apple_help"))
        }
    }

    @ViewBuilder private var fullVersionFooter: some View {
        if purchases.access == .unlocked {
            Label(String(localized: "purchase.owned"), systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .frame(minHeight: 74)
                .accessibilityIdentifier("settings-purchase-owned")
        } else {
            Button {
                showsPurchaseDetail = true
                offerAction = PurchaseOffers.firstSettingsAction(for: purchases)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "lock.open")
                        .foregroundStyle(focusedControl == .purchase ? Color.primary : .yellow)
                        .frame(width: 40)
                        .accessibilityHidden(true)
                    Text(purchases.access == .unverified ? String(localized: "purchase.verify")
                         : String(localized: "settings.unlock_full_version"))
                        .fontWeight(.semibold)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.forward").font(.callout).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
            .buttonStyle(.glass)
            .background {
                if showsPurchaseDetail && focusedControl != .purchase {
                    Capsule().fill(.primary.opacity(0.15))
                }
            }
            .focused($focusedControl, equals: .purchase)
            .accessibilityAddTraits(showsPurchaseDetail ? .isSelected : [])
            .accessibilityIdentifier("settings-purchase")
        }
    }

    private var photoSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.isUsingSampleData
                 ? AppLocalization.string("settings.sample_source", defaultValue: "Exploring a sample trip")
                 : AppLocalization.string("settings.library_source", defaultValue: "From your photo library"))
                .font(.system(size: 26))
            if let index = model.index {
                Text(AppLocalization.format("settings.index_summary", defaultValue: "%1$@ · %2$@",
                                            AppLocalization.itemCount(index.visiblePhotoCount),
                                            AppLocalization.visitCount(index.places.count)))
                    .font(.system(size: 23)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-index-summary")
            }
            if model.usesLivePhotoLibrary {
                actionRow(AppLocalization.string("scan.scope.title", defaultValue: "Albums to Exclude from Scanning")) {
                    model.showScanScope()
                }
                .focused($focusedControl, equals: .scope)
                .accessibilityIdentifier("settings-scan-scope")
            }
            actionRow(model.isUsingSampleData
                   ? AppLocalization.string("settings.connect_photos", defaultValue: "Connect Photo Library")
                   : AppLocalization.string("settings.update", defaultValue: "Check for Library Changes")) {
                returnScanAction = .update
                Task { await model.updateLibrary() }
            }
            .focused($focusedControl, equals: .update)
            .accessibilityIdentifier("settings-scan")
            if model.sampleConnectionDenied {
                caption(AppLocalization.string("permission.message", defaultValue: "In Settings > General > Privacy & Security > Photos, allow PHOTO EARTH to access your photos."))
            }

            if model.supportsTransitFiltering {
                settingSwitch(
                    AppLocalization.string("settings.hide_transit", defaultValue: "Hide Likely Transit Photos"),
                    isOn: Binding(get: { model.hidesTransitPhotos }, set: { enabled in
                        Task { await model.setHidesTransitPhotos(enabled) }
                    }), identifier: "settings-hide-transit"
                )
                .focused($focusedControl, equals: .transit)
                caption(AppLocalization.string("settings.transit_help", defaultValue: "Hide photos and videos whose capture times and locations suggest you were in transit. Favorites stay visible."))
                if model.hidesTransitPhotos, let index = model.index {
                    Text(AppLocalization.format("settings.transit_count", defaultValue: "%lld items hidden",
                                                Int64(index.hiddenTransitPhotoCount)))
                        .font(.system(size: 23)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-transit-count")
                }
                if let error = model.transitFilterError { caption(error) }
            }

            actionRow(journeyMinimumTitle, value: AppLocalization.number(model.minimumJourneyItems)) {
                journeyMinimumText = String(model.minimumJourneyItems)
                showsJourneyMinimum = true
            }
            .focused($focusedControl, equals: .journeyMinimum)
            .accessibilityLabel(journeyMinimumTitle)
            .accessibilityValue(AppLocalization.number(model.minimumJourneyItems))
            .accessibilityIdentifier("settings-journey-minimum")

            if !model.isUsingSampleData, let index = model.index {
                actionRow(AppLocalization.string("settings.scan_details", defaultValue: "Scan Details"),
                          symbol: showsScanDetails ? "chevron.up" : "chevron.down") {
                    showsScanDetails.toggle()
                    if showsScanDetails { analytics.capture(.settingsOpenedReference, value: "scan_details") }
                }
                .accessibilityValue(showsScanDetails
                    ? AppLocalization.string("settings.expanded", defaultValue: "Expanded")
                    : AppLocalization.string("settings.collapsed", defaultValue: "Collapsed"))
                .focused($focusedControl, equals: .scanDetails)
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
            caption(AppLocalization.string("journey.minimum.note", defaultValue: "A visit appears in Recently Visited when it has at least this many photos and videos with a location. Its city can then appear on Home and on the Apple TV Home Screen."))
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
                    .accessibilityHint(rangeText)
                    .accessibilityIdentifier("settings-journey-minimum-custom")
                Text(rangeText).fixedSize().foregroundStyle(.secondary).accessibilityHidden(true)
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
        caption(AppLocalization.string("settings.privacy_message", defaultValue: "Capture times, locations, and camera information help organize your trips on this Apple TV. Your original photos and videos stay unchanged."))
        caption(AppLocalization.format("settings.last_organized", defaultValue: "Last organized %@",
                                       dateString(index.generatedAt)))
            .task(id: index.contentRevision) { await model.refreshScanDetails() }
        if let check = model.lastLibraryCheck {
            caption(AppLocalization.format("settings.last_checked", defaultValue: "Photos checked %@", dateString(check)))
        }
        if let names = model.preparationProgress.visitNames {
            caption(AppLocalization.format("settings.label_summary", defaultValue: "Visits: %1$@ · City identified: %2$@ · Country or region only: %3$@ · Unknown: %4$@",
                                           AppLocalization.number(names.total), AppLocalization.number(names.city),
                                           AppLocalization.number(names.regionOnly), AppLocalization.number(names.unknown)))
                .accessibilityIdentifier("settings-place-name-summary")
        }
        if model.preparationProgress.phase == .complete, let retry = model.preparationProgress.retryAt {
            caption(AppLocalization.format("preparation.retry_at", defaultValue: "Continues automatically · %@",
                                           retry.formatted(.dateTime.hour().minute().locale(AppLocalization.locale))))
        }
        if model.preparationProgress.canContinuePlaceNames {
            actionRow(AppLocalization.string("settings.complete_places", defaultValue: "Complete Place Names")) {
                returnScanAction = .complete
                Task { await model.updateLibrary(.labels) }
            }
            .focused($focusedControl, equals: .complete)
            .accessibilityIdentifier("settings-complete-places")
        }
        actionRow(AppLocalization.string("settings.rebuild", defaultValue: "Rescan Photos and Videos")) {
            returnScanAction = .rebuild
            Task { await model.updateLibrary(.rebuild) }
        }
        .focused($focusedControl, equals: .rebuild)
        .accessibilityIdentifier("settings-rebuild")
        caption(AppLocalization.string("settings.rebuild_message", defaultValue: "Scan photos and videos again using your current settings. Previously identified place names are kept."))
    }

    private var homeScreenSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingSwitch(
                AppLocalization.string("settings.journeys_on_home", defaultValue: "Show Recently Visited Cities"),
                isOn: Binding(get: { model.showsJourneysOnTopShelf }, set: { enabled in
                    model.setShowsJourneysOnTopShelf(enabled)
                    homeScreenUpdateFailed = model.showsJourneysOnTopShelf != enabled
                }),
                identifier: "settings-top-shelf"
            )
            .focused($focusedControl, equals: .home)
            if homeScreenUpdateFailed {
                caption(AppLocalization.string("settings.transit_error", defaultValue: "Couldn’t update this setting. Please try again."))
            }
            caption(AppLocalization.string("settings.home_screen_help", defaultValue: "Place PHOTO EARTH in the top row and highlight its icon to preview city photos from your library. Available during your trial and with the full version."))
        }
    }

    private var globeSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingSwitch(AppLocalization.string("settings.show_hints", defaultValue: "Show Globe Control Hints"),
                          isOn: Binding(get: { showsGlobeHints }, set: { enabled in
                              showsGlobeHints = enabled
                              ProductAnalytics.shared.capture(.settingsChanged, value: "globe_hints")
                          }), identifier: "settings-globe-hints")
                .focused($focusedControl, equals: .hints)
            settingSwitch(AppLocalization.string("settings.wait_for_globe", defaultValue: "Wait for Globe Imagery"),
                          isOn: Binding(get: { waitsForInitialGlobeRender }, set: { enabled in
                              waitsForInitialGlobeRender = enabled
                              ProductAnalytics.shared.capture(.settingsChanged, value: "globe_imagery")
                          }), identifier: "settings-wait-for-globe")
                .focused($focusedControl, equals: .imagery)
            caption(String(localized: "settings.wait_for_globe_message"))
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

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 23)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().locale(AppLocalization.locale))
    }
}
