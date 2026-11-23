import SwiftUI

struct GlobeOverviewView: View {
    let content: OverviewContentModel
    let isUsingSampleData: Bool
    var showsFreeJourneyHint = false
    let enterGlobe: () -> Void
    var startSlideshow: (() -> Void)? = nil
    let openPlace: (TravelPlace) -> Void
    let prepareSatelliteCity: (GeoCoordinate?) -> Void
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedID: String?
    @State private var focusHandoff = OverviewFocusHandoff()
    @State private var isBelowPageTop = false

    private let placesPerShelf = 5
    private let horizontalInset: CGFloat = 80
    private let shelfSpacing: CGFloat = 34
    private var shelfInset: CGFloat { FullScreenMapLayout.contentHorizontalInset - horizontalInset }
    private let entryFocusID = OverviewFocusHandoff.entryID
    private let slideshowFocusID = "home-slideshow"

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = (geometry.size.width - horizontalInset * 2 - shelfInset * 2
                             - shelfSpacing * CGFloat(placesPerShelf - 1)) / CGFloat(placesPerShelf)

            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    // Keep loaded shelf destinations in the native focus graph.
                    // A lazy full-screen first child can trap focus in the dock.
                    // Place data and image requests still expand in small batches.
                    VStack(alignment: .leading, spacing: 48) {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            actions
                                // Leave the native scan-progress focus row above these buttons.
                                .padding(.top, isUsingSampleData ? 28 : 84)
                            if showsFreeJourneyHint {
                                Text(String(localized: "purchase.firstJourney"))
                                    .font(.system(size: 23)).foregroundStyle(.secondary)
                                    .padding(.top, 18)
                            }
                            Spacer(minLength: 200)
                            recentShelf(cardWidth: cardWidth)
                                .id("places-shelf-0")
                        }
                        .frame(height: geometry.size.height)
                        .id("overview-top")

                        ForEach(content.shelves) { shelf in
                            placeShelf(shelf, cardWidth: cardWidth)
                                .id(shelf.id)
                        }

                        if content.hasMore {
                            Button(AppLocalization.string("library.load_more", defaultValue: "Show More Places"), action: content.expand)
                                .font(.system(size: 29, weight: .medium))
                                .buttonStyle(.glass)
                                .focused($focusedID, equals: "load-more-places")
                                .id("load-more-places")
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("overview-load-more")
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, 80)
                }
                .scrollClipDisabled()
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 8
                } action: { _, belowTop in
                    isBelowPageTop = belowTop
                    if !belowTop, focusHandoff.phase == .returningToTop, focusedID != entryFocusID {
                        focusedID = entryFocusID
                    }
                    commitFocus()
                }
                .onScrollPhaseChange { _, phase in content.scrollChanged(moving: phase != .idle) }
                .onChange(of: content.structureRevision) { _, _ in
                    if focusHandoff.phase == .browsing, let focusedID, content.validFocusID(focusedID) != focusedID {
                        self.focusedID = content.validFocusID(content.restoredFocusID)
                    }
                }
                .onChange(of: focusedID) { _, _ in commitFocus() }
                .onExitCommand(perform: handlesHomeBack ? { returnToPageTop(using: scroll) } : nil)
                .task(id: isActive) {
                    content.setActive(isActive)
                    guard isActive else {
                        focusHandoff.deactivate()
                        focusedID = nil
                        return
                    }
                    let restoredID = validRestoredFocusID
                    focusHandoff.restore(restoredID)
                    await Task.yield()
                    guard !Task.isCancelled, focusHandoff.phase == .restoring(restoredID) else { return }
                    if restoredID != entryFocusID, restoredID != slideshowFocusID {
                        scroll.scrollTo(content.scrollTarget(restoredID), anchor: .center)
                    } else if isBelowPageTop {
                        scroll.scrollTo("overview-top", anchor: .top)
                    }
                    focusedID = restoredID
                    commitFocus()
                }
            }
        }
        .foregroundStyle(.white)
        .defaultFocus($focusedID, validRestoredFocusID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("globe-overview")
        .task(id: satelliteFocus) {
            prepareSatelliteCity(nil)
            guard let city = satelliteFocus else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            prepareSatelliteCity(city)
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoAssetChangeNotice.name)) { notice in
            content.invalidateImages(changed: notice.userInfo?["changed"] as? Set<String> ?? [],
                                     removed: notice.userInfo?["removed"] as? Set<String> ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            content.images.memoryWarning()
        }
        .onDisappear {
            prepareSatelliteCity(nil)
            content.setActive(false)
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--home-performance") {
                OverviewPerformanceReadout(content: content)
            }
        }
#endif
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            Text(verbatim: "PHOTO EARTH")
                .font(.custom("AvenirNext-DemiBold", fixedSize: 32))
                .accessibilityAddTraits(.isHeader)
                .tracking(2)
                .foregroundStyle(.white.opacity(0.88))
                .frame(height: 45)
            if isUsingSampleData {
                Text(AppLocalization.string("sample.journey", defaultValue: "Sample Trip"))
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: 88, alignment: .top)
    }

    private var actions: some View {
        HStack(spacing: TVControlLayout.actionSpacing) {
            EarthEntryButton(kind: .explore, title: AppLocalization.string("home.explore_globe", defaultValue: "Explore the Globe"),
                            action: enterGlobe)
            .focused($focusedID, equals: entryFocusID)
            .id(entryFocusID)
            .accessibilityHint(AppLocalization.string("home.explore_hint", defaultValue: "Turn the globe with the remote, then press the clickpad center or touch surface to browse visible photos."))
            .accessibilityIdentifier("overview-explore-button")

            if let startSlideshow {
                EarthSlideshowEntryButton {
                    content.focusChanged(slideshowFocusID)
                    startSlideshow()
                }
                .focused($focusedID, equals: slideshowFocusID)
                .id(slideshowFocusID)
                .accessibilityIdentifier("overview-slideshow")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func recentShelf(cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text(AppLocalization.string("home.recent_arrivals", defaultValue: "Recently Visited Cities"))
                    .font(.system(size: 29, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !content.shelves.isEmpty {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, shelfInset)
            .shadow(color: .black.opacity(0.8), radius: 4, y: 1)

            if content.recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let notice = AppLocalization.visitFilterNotice(belowMinimum: content.hasVisitsBelowMinimum,
                                                                      hiddenTransitItems: content.hiddenTransitPhotoCount) {
                        Text(notice.title)
                        Text(notice.help).font(.system(size: 23))
                    } else {
                        Text(AppLocalization.string("home.empty", defaultValue: "No visits yet"))
                    }
                }
                .font(.system(size: 29, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
                .padding(.horizontal, shelfInset)
            } else {
                HStack(spacing: shelfSpacing) {
                    ForEach(content.recent) { place in
                        placeCard(place, width: cardWidth, isArrival: true)
                    }
                }
                .padding(.horizontal, shelfInset)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }
        }
        .focusSection()
    }

    private func placeShelf(_ shelf: OverviewPlaceShelf, cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if shelf.showsYearHeading {
                Text(shelf.year.formatted(.number.grouping(.never).locale(AppLocalization.locale)))
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("overview-year-\(shelf.year)")
            }

            HStack(spacing: shelfSpacing) {
                ForEach(shelf.items) { place in
                    placeCard(place, width: cardWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
        .padding(.horizontal, shelfInset)
        .focusSection()
    }

    private func placeCard(_ item: OverviewPlaceItem, width: CGFloat, isArrival: Bool = false) -> some View {
        let focusID = "place-\(item.id)"
        let isFocused = focusedID == focusID
        return OverviewPlaceCard(item: item, width: width, isArrival: isArrival,
                                 isFocused: isFocused, isActive: isActive, openPlace: openPlace)
            .focused($focusedID, equals: focusID)
            .id(focusID)
            .zIndex(isFocused ? 1 : 0)
            .onScrollVisibilityChange(threshold: 0.05) { visible in
                content.visibilityChanged(item.id, visible: visible)
            }
            .accessibilityIdentifier("overview-place-\(item.id)")
    }

    private var validRestoredFocusID: String {
        let id = content.validFocusID(content.restoredFocusID)
        return id == slideshowFocusID && startSlideshow == nil ? entryFocusID : id
    }

    private var satelliteFocus: GeoCoordinate? {
        isActive && !reduceMotion ? content.coordinate(forFocus: focusedID) : nil
    }

    private var handlesHomeBack: Bool {
        isActive && focusHandoff.handlesBack(hasFocus: focusedID != nil,
            belowTop: isBelowPageTop || content.isPastRecentDock(focusedID))
    }

    private func commitFocus() {
        guard isActive, let accepted = focusHandoff.accept(focusedID, atTop: !isBelowPageTop) else { return }
        content.focusChanged(accepted)
    }

    private func returnToPageTop(using scroll: ScrollViewProxy) {
        focusHandoff.returnToTop()
        content.focusChanged(entryFocusID)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            focusedID = entryFocusID
            scroll.scrollTo("overview-top", anchor: .top)
        }
        commitFocus()
    }
}

private struct OverviewPlaceCard: View {
    let item: OverviewPlaceItem
    let width: CGFloat
    let isArrival: Bool
    let isFocused: Bool
    let isActive: Bool
    let openPlace: (TravelPlace) -> Void

    var body: some View {
        PlaceCard(place: item.place, isSelected: false, isFocused: isFocused,
                  cardWidth: width, isArrival: isArrival, usesManagedThumbnail: true,
                  thumbnail: item.thumbnail, waitingForSelection: isActive && !item.scenicPrepared, coverUnavailable: item.coverFailed, action: { openPlace(item.place) })
            .accessibilityValue(item.thumbnail?.image == nil
                ? AppLocalization.string("photo.pending", defaultValue: "Photo pending")
                : AppLocalization.string("photo.loaded", defaultValue: "Photo loaded"))
    }
}

#if DEBUG
private struct OverviewPerformanceReadout: View {
    let content: OverviewContentModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let images = content.images
            let metrics = images.metrics
            Text(verbatim: "loaded=\(content.loadedCount);local=\(metrics.localRequests);cloud=\(metrics.networkRequests);hits=\(metrics.cacheHits);bytes=\(images.accountedBytes);peakBytes=\(metrics.peakAccountedBytes);images=\(images.retainedImageCount);active=\(images.activeRequestCount);maxLocal=\(metrics.peakLocal);maxCloud=\(metrics.peakNetwork);row=\(content.focusedShelfIndex);")
                .font(.system(size: 1)).opacity(0.01)
                .accessibilityIdentifier("overview-performance")
        }.allowsHitTesting(false)
    }
}
#endif
