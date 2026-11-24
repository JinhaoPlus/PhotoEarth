import SwiftUI

struct PlaceLibraryView: View {
    enum Mode { case recent, countries }
    @ObservedObject var model: AppModel
    let mode: Mode
    var isActive = true
    let openPhotos: (PlaceCollection) -> Void
    @State private var selectedCountryID: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var countries: [PlaceCollection] {
        guard let index = model.index else { return [] }
        return PlaceCollection.countries(index.places, journeys: index.journeys, excluding: model.excludedAssetIDs)
    }

    var body: some View {
        Group {
            if mode == .recent {
                PlaceCollectionGrid(model: model,
                                    collections: PlaceCollection.recent(model.index?.places ?? [], minimumVisitItems: model.minimumJourneyItems),
                                    groupsVisitsByMonth: true, isActive: isActive, open: openPhotos)
            } else {
                let countries = self.countries
                let selectedCountry = countries.first { $0.id == selectedCountryID }
                ZStack {
                    PlaceCollectionGrid(model: model,
                                        collections: countries, isActive: isActive && selectedCountry == nil,
                                        open: { country in
                                            selectedCountryID = country.id
                                            ProductAnalytics.shared.capture(.countryOpened, context: .init(library: model.analyticsLibrary))
                                        })
                        .opacity(selectedCountry == nil ? 1 : 0)
                        .disabled(selectedCountry != nil)
                        .accessibilityHidden(selectedCountry != nil)
                    if let country = selectedCountry {
                        PlaceCollectionGrid(model: model,
                                            collections: country.cities, allPhotos: country,
                                            back: { selectedCountryID = nil }, isActive: isActive, open: openPhotos)
                            .id(country.id)
                    }
                }
            }
        }
        .background {
            ZStack {
                Color(red: 0.008, green: 0.018, blue: 0.032)
                    .opacity(reduceTransparency ? 1 : 0.5)
                LinearGradient(
                    colors: [
                        .black.opacity(reduceTransparency ? 0 : 0.22),
                        .clear,
                        .black.opacity(reduceTransparency ? 0 : 0.46),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
    }
}

private struct PlaceCollectionGrid: View {
    @ObservedObject var model: AppModel
    let collections: [PlaceCollection]
    var groupsVisitsByMonth = false
    var allPhotos: PlaceCollection?
    var back: (() -> Void)?
    var isActive = true
    let open: (PlaceCollection) -> Void

    @State private var limit = PlaceGridPaging.libraryColumns * 4
    @State private var presentation: Presentation?
    private struct CoverInput {
        let key: String
        let fallback: PhotoPreviewMetadata?
    }
    @State private var coverInputs: [String: CoverInput] = [:]
    private struct EvaluatedCover {
        let assetID: String
        let key: String
        let visitID: String?
    }
    @State private var selectionTasks: [String: UUID] = [:]
    @State private var scenicAssets: [String: EvaluatedCover] = [:]
    @State private var preparedPlaceIDs = Set<String>()
    @State private var settledResidentCollectionIDs = Set<String>()
    @FocusState private var focusedID: String?
    @State private var rememberedFocusID: String?
    @State private var scrollPosition = ScrollPosition()
    @State private var isBelowPageTop = false
    @State private var isReturningToTop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columnSpacing: CGFloat = 28
    private let allPhotosFocusID = "library-country-photos"
    private let emptyFocusID = "library-empty"

    var body: some View {
        let input = PresentationInput(collections: collections.prefix(limit + PlaceGridPaging.libraryColumns - 1), target: limit,
                                      calendar: .current, locale: AppLocalization.locale)
        let presentation = self.presentation ?? makePresentation(input)
        let topFocusID = allPhotos != nil ? allPhotosFocusID : (presentation.cards.first?.collection.id ?? emptyFocusID)
        let handlesBack = isActive && (isReturningToTop || (focusedID != nil && (isBelowPageTop || back != nil)))
        let contentKey = "\(isActive):\(model.index?.contentRevision ?? ""):\(model.coverRevision):" + presentation.membership
        GeometryReader { geometry in
            let width = (geometry.size.width - 2 * FullScreenMapLayout.contentHorizontalInset - CGFloat(PlaceGridPaging.libraryColumns - 1) * columnSpacing) / CGFloat(PlaceGridPaging.libraryColumns)
            let focusIndex = focusedID.flatMap { presentation.positions[$0] }
            let focusRow = focusIndex.map { presentation.rowIndices[$0] } ?? 0
            // Four-column library cards need a slightly wider row buffer than
            // the five-column home shelves. Keep two rows on either side so an
            // edge row does not lose its image while tvOS scrolls the new focus
            // into place.
            let desiredResidentIndices = OverviewImageWindow.residentIndices(
                shelfRanges: presentation.ranges,
                focusedShelfIndex: focusRow,
                shelfRadius: OverviewImageWindow.collectionGridShelfRadius,
                imageLimit: OverviewImageWindow.collectionGridMaximumResidentImages
            )
            let desiredResidentCollectionIDs = Set(desiredResidentIndices.map { presentation.cards[$0].collection.id })
            // During the native scroll animation both windows can still be on
            // screen. Their short-lived union prevents the outgoing branch from
            // being synchronously replaced by a placeholder.
            let residentCollectionIDs = isActive
                ? settledResidentCollectionIDs.union(desiredResidentCollectionIDs)
                : []
            let residencyKey = ImageResidencyKey(
                isActive: isActive,
                collectionIDs: desiredResidentCollectionIDs.sorted()
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let allPhotos {
                        HStack(alignment: .center, spacing: 32) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(allPhotos.titleWithCountryFlag).font(.system(size: 52, weight: .light))
                                    .accessibilityAddTraits(.isHeader)
                                Text(AppLocalization.format("library.country.summary", defaultValue: "%1$@ · %2$@", allPhotos.subtitle, AppLocalization.itemCount(allPhotos.photoCount)))
                                    .font(.system(size: 26)).foregroundStyle(.white.opacity(0.65))
                            }
                            Button(AppLocalization.string("library.all_photos", defaultValue: "View All Photos"), systemImage: "photo.on.rectangle") { open(allPhotos) }
                                .labelStyle(PageActionLabelStyle())
                                .buttonStyle(.glass)
                                .fixedSize()
                                .focused($focusedID, equals: allPhotosFocusID)
                                .accessibilityIdentifier(allPhotosFocusID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                        .onMoveCommand { direction in
                            if direction == .down, let firstCity = presentation.cards.first {
                                focusedID = firstCity.collection.id
                            }
                        }
                    }

                    if collections.isEmpty && allPhotos == nil {
                        let notice = AppLocalization.visitFilterNotice(
                            belowMinimum: groupsVisitsByMonth && !(model.index?.places.isEmpty ?? true),
                            hiddenTransitItems: model.index?.hiddenTransitPhotoCount ?? 0
                        )
                        ContentUnavailableView(
                            notice?.title ?? AppLocalization.string("library.empty.title", defaultValue: "No Places Yet"),
                            systemImage: "globe.asia.australia",
                            description: Text(notice?.help ?? AppLocalization.string(
                                "library.empty.message", defaultValue: "Photos with a date and location will appear here."))
                        )
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focusedID, equals: emptyFocusID)
                            .accessibilityIdentifier(emptyFocusID)
                    }

                    // Loaded destinations participate in tvOS focus. Image residency
                    // and metadata preparation have their own bounded windows.
                    ForEach(presentation.sections) { section in
                        collectionSection(section, presentation: presentation, width: width,
                                          residentCollectionIDs: residentCollectionIDs,
                                          focusIndex: focusIndex, focusRow: focusRow)
                    }
                }
                .padding(.horizontal, FullScreenMapLayout.contentHorizontalInset)
                .padding(.top, 110)
                .padding(.bottom, 88)
            }
            .scrollClipDisabled()
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 8
            } action: { _, belowTop in
                isBelowPageTop = belowTop
                if isReturningToTop, !belowTop {
                    focusedID = topFocusID
                    finishReturningToTop(topFocusID)
                }
            }
            .onExitCommand(perform: handlesBack ? { handleBack(topFocusID: topFocusID) } : nil)
            .defaultFocus($focusedID, topFocusID)
            .task(id: residencyKey) {
                guard isActive else {
                    settledResidentCollectionIDs = []
                    return
                }
                if settledResidentCollectionIDs.isEmpty {
                    settledResidentCollectionIDs = desiredResidentCollectionIDs
                    return
                }
                guard settledResidentCollectionIDs != desiredResidentCollectionIDs else { return }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard !Task.isCancelled, isActive else { return }
                settledResidentCollectionIDs = desiredResidentCollectionIDs
            }
        }
        .onChange(of: input, initial: true) { _, input in
            self.presentation = makePresentation(input)
        }
        .onChange(of: focusedID) { _, id in
            guard isActive, let id else { return }
            if isReturningToTop {
                finishReturningToTop(topFocusID)
                return
            }
            rememberedFocusID = id
            guard let index = presentation.positions[id], index >= presentation.cards.count - 4 else { return }
            loadMore(after: presentation.cards.count)
        }
        .task(id: isActive) {
            guard isActive, let rememberedFocusID else { return }
            let isAvailable = rememberedFocusID == topFocusID || presentation.positions[rememberedFocusID] != nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedID = isAvailable ? rememberedFocusID : topFocusID
        }
        .task(id: contentKey) {
            await prepareCards(presentation.cards)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                isReturningToTop = false
                scenicAssets.removeAll()
                coverInputs.removeAll()
            }
        }
        .onChange(of: model.excludedAssetIDs) { _, excluded in
            scenicAssets = scenicAssets.filter { !excluded.contains($0.value.assetID) }
        }
        .onChange(of: model.index?.generatedAt) { _, _ in
            preparedPlaceIDs = []
        }
        .accessibilityIdentifier("place-library")
    }

    private func handleBack(topFocusID: String) {
        guard !isReturningToTop else { return }
        guard isBelowPageTop else {
            back?()
            return
        }
        isReturningToTop = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            focusedID = topFocusID
            scrollPosition.scrollTo(edge: .top)
        }
    }

    private func finishReturningToTop(_ topFocusID: String) {
        guard !isBelowPageTop, focusedID == topFocusID else { return }
        rememberedFocusID = topFocusID
        isReturningToTop = false
    }

    private func prepareCards(_ cards: [Card]) async {
        guard isActive else { return }
        let revision = model.index?.contentRevision
        let coverRevision = model.coverRevision
        var cardsToPrepare: [Card] = []
        for card in cards {
            guard let place = card.collection.latestPlace,
                  preparedPlaceIDs.contains(place.id) || preparedPlaceIDs.count < cards.count else { continue }
            preparedPlaceIDs.insert(place.id)
            let key = scenicKey(for: card)
            if scenicAssets[card.collection.id]?.key != key, coverInputs[card.collection.id]?.key != key {
                cardsToPrepare.append(card)
            }
        }
        guard !cardsToPrepare.isEmpty else { return }
        func isCurrent() -> Bool {
            !Task.isCancelled && revision == model.index?.contentRevision && coverRevision == model.coverRevision
        }
        let visits = cardsToPrepare.filter(\.usesScenicCover)
        var held: [String: String] = [:]
        for card in visits {
            if let visit = card.collection.latestPlace, let selected = scenicAssets[card.collection.id],
               selected.visitID == visit.id { held[visit.id] = selected.assetID }
        }
        let saved = await model.savedVisitCovers(for: visits.compactMap(\.collection.latestPlace), keeping: held)
        guard isCurrent() else { return }
        var pending: [Card] = []
        for card in cardsToPrepare {
            guard isCurrent() else { return }
            let id = card.collection.id
            let place = card.collection.latestPlace
            let key = scenicKey(for: card)
            if card.collection.usesCountryJourneyCover { continue }
            if card.usesScenicCover, let place, let winner = saved[place.id] {
                scenicAssets[id] = EvaluatedCover(assetID: winner.assetID, key: key, visitID: place.id)
            } else if !card.usesScenicCover, let held = scenicAssets[id],
                      await model.isVisibleCover(held.assetID, in: card.collection) {
                guard isCurrent() else { return }
                scenicAssets[id] = EvaluatedCover(assetID: held.assetID, key: key, visitID: nil)
            } else {
                pending.append(card)
            }
        }
        guard isCurrent() else { return }
        let labelIDs = cardsToPrepare.compactMap(\.collection.latestPlace?.id)
        async let labels: Void = model.resolvePlaceLabels(for: labelIDs)
        for start in stride(from: 0, to: pending.count, by: 15) {
            let batch = pending[start..<min(start + 15, pending.count)]
            let latest = (try? await model.latestPhotoPreviews(for: batch.compactMap(\.collection.latestPlace))) ?? [:]
            guard isCurrent() else { return }
            for card in batch {
                guard let place = card.collection.latestPlace else { continue }
                let fallback = latest[place.id] ?? place.coverAssetID.map { PhotoPreviewMetadata(assetID: $0) }
                coverInputs[card.collection.id] = CoverInput(key: scenicKey(for: card), fallback: fallback)
            }
        }
        await labels
    }

    private func loadMore(after displayedCount: Int) {
        guard isActive, displayedCount >= limit, displayedCount < collections.count else { return }
        limit = displayedCount + 2 * PlaceGridPaging.libraryColumns
    }

    private struct PresentationInput: Equatable {
        let collections: ArraySlice<PlaceCollection>
        let target: Int
        let calendar: Calendar
        let locale: Locale
    }

    private struct Card {
        let collection: PlaceCollection
        let title: AttributedString
        let summary: String
        let accessibilitySummary: String?
        let usesScenicCover: Bool
        let placeKey: String
    }

    private struct Presentation {
        let calendar: Calendar
        let locale: Locale
        let cards: [Card]
        let sections: [CollectionGridSection]
        let ranges: [Range<Int>]
        let positions: [String: Int]
        let rowIndices: [Int]
        let membership: String
    }

    private func makePresentation(_ input: PresentationInput) -> Presentation {
        let previous = self.presentation
        let canReuseCaptions = previous?.calendar == input.calendar && previous?.locale == input.locale
        let pageEnd = PlaceGridPaging.pageEnd(through: input.target, count: input.collections.count,
                                              columns: PlaceGridPaging.libraryColumns) { index in
            guard groupsVisitsByMonth, let previous = input.collections[index - 1].latestPlace?.endDate,
                  let current = input.collections[index].latestPlace?.endDate else { return false }
            return !input.calendar.isDate(previous, equalTo: current, toGranularity: .month)
        }
        let page = input.collections.prefix(pageEnd)
        let cards = page.enumerated().map { index, collection in
            if canReuseCaptions, let previous, previous.cards.indices.contains(index),
               previous.cards[index].collection == collection {
                return previous.cards[index]
            }
            let count = AppLocalization.itemCount(collection.photoCount, locale: input.locale)
            let summary: String
            let accessibilitySummary: String?
            if groupsVisitsByMonth, let place = collection.latestPlace {
                let compact = AppLocalization.recentVisitDateRange(from: place.startDate, to: place.endDate, locale: input.locale)
                summary = "\(compact) · \(count)"
                accessibilitySummary = "\(place.dateRangeText) · \(count)"
            } else if case .country = collection.scope {
                summary = AppLocalization.format("library.country.summary", defaultValue: "%1$@ · %2$@", collection.subtitle, count)
                accessibilitySummary = nil
            } else {
                summary = count
                accessibilitySummary = nil
            }
            return Card(collection: collection, title: cardTitle(for: collection), summary: summary,
                        accessibilitySummary: accessibilitySummary, usesScenicCover: collection.representsSingleCity,
                        placeKey: collection.placeIDs.sorted().map { "\($0.utf8.count):\($0)" }.joined())
        }
        let sections = gridSections(for: Array(page), calendar: input.calendar)
        let ranges = sections.flatMap(\.rowRanges)
        let positions = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($0.element.collection.id, $0.offset) })
        let rowIndices = ranges.enumerated().flatMap { index, row in Array(repeating: index, count: row.count) }
        let membership = cards.map {
            "\($0.collection.id):\($0.collection.latestPlace?.id ?? ""):\($0.placeKey)"
        }.joined(separator: "|")
        return Presentation(calendar: input.calendar, locale: input.locale, cards: cards,
                            sections: sections, ranges: ranges, positions: positions,
                            rowIndices: rowIndices, membership: membership)
    }

    private func gridSections(for collections: [PlaceCollection], calendar: Calendar) -> [CollectionGridSection] {
        guard groupsVisitsByMonth else {
            return [CollectionGridSection(id: "all", monthTitle: nil, rowRanges: rowRanges(in: 0..<collections.count))]
        }
        var offset = 0
        return PlaceCollection.recentMonths(inRecencyOrder: collections, calendar: calendar).map { month in
            let range = offset..<(offset + month.visits.count)
            offset = range.upperBound
            return CollectionGridSection(
                id: "month-\(month.startDate.timeIntervalSinceReferenceDate)",
                monthTitle: AppLocalization.monthTitle(month.startDate),
                rowRanges: rowRanges(in: range)
            )
        }
    }

    private func rowRanges(in range: Range<Int>) -> [Range<Int>] {
        stride(from: range.lowerBound, to: range.upperBound, by: PlaceGridPaging.libraryColumns).map {
            $0..<min($0 + PlaceGridPaging.libraryColumns, range.upperBound)
        }
    }

    private func collectionSection(
        _ section: CollectionGridSection, presentation: Presentation, width: CGFloat,
        residentCollectionIDs: Set<String>, focusIndex: Int?, focusRow: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let monthTitle = section.monthTitle {
                Label(monthTitle, systemImage: "calendar")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("library-recent-month-title")
            }
            VStack(alignment: .leading, spacing: 30) {
                ForEach(section.rowRanges, id: \.lowerBound) { row in
                    collectionRow(row, presentation: presentation, width: width,
                                  residentCollectionIDs: residentCollectionIDs, focusIndex: focusIndex,
                                  isFocusedRow: presentation.rowIndices[row.lowerBound] == focusRow && focusIndex != nil)
                }
            }
        }
    }

    private func collectionRow(
        _ row: Range<Int>,
        presentation: Presentation,
        width: CGFloat,
        residentCollectionIDs: Set<String>,
        focusIndex: Int?,
        isFocusedRow: Bool
    ) -> some View {
        let cards = presentation.cards
        return HStack(alignment: .top, spacing: columnSpacing) {
            ForEach(row, id: \.self) { index in
                let card = cards[index]
                let id = card.collection.id
                collectionCard(card, width: width, loadsImage: residentCollectionIDs.contains(id),
                               isOpeningCard: index < 4 && (focusIndex ?? 0) < 4,
                               isFocused: index == focusIndex, imagePriority: index == focusIndex ? .focus : isFocusedRow ? .visible : .prefetch)
                    .focused($focusedID, equals: id)
            }
        }
        // Give every visual row a full-width focus section. Without this, a
        // down press from column two can geometrically miss a following row
        // that contains only one card and jump to a later month instead.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onScrollVisibilityChange(threshold: 0.05) { visible in
            guard visible, let start = PlaceGridPaging.preloadStart(in: presentation.ranges, columns: PlaceGridPaging.libraryColumns),
                  row.lowerBound >= start else { return }
            loadMore(after: cards.count)
        }
    }

    private struct ImageResidencyKey: Hashable {
        let isActive: Bool
        let collectionIDs: [String]
    }

    private func collectionCard(_ card: Card, width: CGFloat, loadsImage: Bool,
                                isOpeningCard: Bool, isFocused focused: Bool, imagePriority: PhotoImagePriority) -> some View {
        let collection = card.collection
        let visitCover = card.usesScenicCover
        let usesOriginalCover = visitCover || collection.usesCountryJourneyCover
        let selected = scenicAssets[collection.id]
        let key = scenicKey(for: card)
        let displayAsset = collection.usesCountryJourneyCover
            ? collection.countryJourneyCoverAssetID
            : (selected?.key == key ? selected?.assetID : nil)
        let input = coverInputs[collection.id]
        let needsSelection = isActive && loadsImage && input?.key == key && displayAsset == nil
        return Button { open(collection) } label: {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if loadsImage, let asset = displayAsset, !model.excludedAssetIDs.contains(asset) {
                        PhotoAssetImage(assetID: asset, targetSize: CGSize(width: 640, height: 400),
                                        isActive: isActive, priority: imagePriority, usesOriginalCover: usesOriginalCover, reportsCoverPhase: true,
                                        initialImage: SharedPhotoImageScheduler.shared.cachedPreview(for: asset, maximumLongEdge: 640, fullFrameOnly: usesOriginalCover))
                    } else if loadsImage && !collection.usesCountryJourneyCover {
                        if needsSelection, selectionTasks[collection.id] != nil {
                            Color.clear.preference(key: CoverDisplayPreference.self, value: .waiting)
                        } else {
                            WaitingCoverView()
                        }
                    } else {
                        Rectangle().fill(.white.opacity(0.07))
                            .overlay { Image(systemName: "photo").font(.system(size: 36, weight: .ultraLight)) }
                    }
                }
                .frame(width: width, height: width * 0.59)
                .overlayPreferenceValue(CoverDisplayPreference.self) { phase in
                    CoverLoadingOverlay(phase: phase, focused: focused)
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 3 : 1) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.title)
                        .font(.system(size: 29, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                        .accessibilityIdentifier("library-place-title-\(collection.id)")
                    if let accessibilitySummary = card.accessibilitySummary {
                        Text(card.summary)
                            .font(.system(size: 23)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                            .accessibilityLabel(accessibilitySummary)
                            .accessibilityIdentifier("library-visit-summary-\(collection.id)")
                    } else {
                        Text(card.summary)
                            .font(.system(size: 23)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(focused && !reduceMotion ? 1.025 : 1)
            .shadow(color: .black.opacity(0.3), radius: focused ? 16 : 0, y: 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
        }
        .task(id: "\(needsSelection):\(key)") {
            guard needsSelection, let input else { return }
            if !isOpeningCard {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            }
            let token = UUID()
            selectionTasks[collection.id] = token
            defer {
                if selectionTasks[collection.id] == token { selectionTasks.removeValue(forKey: collection.id) }
            }
            let preferred = await model.preferredCover(for: collection, fallback: input.fallback)
            guard !Task.isCancelled, key == scenicKey(for: card), let preferred,
                  !model.excludedAssetIDs.contains(preferred.assetID), scenicAssets[collection.id]?.key != key else { return }
            scenicAssets[collection.id] = EvaluatedCover(assetID: preferred.assetID, key: key,
                                                        visitID: visitCover ? collection.latestPlace?.id : nil)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .accessibilityIdentifier("library-collection-\(collection.id)")
    }

    private func cardTitle(for collection: PlaceCollection) -> AttributedString {
        if let place = collection.latestPlace,
           groupsVisitsByMonth || allPhotos?.scope == .country("unresolved") {
            return PlaceDisplayLabel(place: place).styledName(citySize: 29)
        }
        return AttributedString(collection.titleWithCountryFlag)
    }

    private func scenicKey(for card: Card) -> String {
        "\(model.index?.contentRevision ?? ""):\(model.coverRevision):\(card.collection.latestPlace?.id ?? ""):" + card.placeKey
    }
}

private struct CollectionGridSection: Identifiable {
    let id: String
    let monthTitle: String?
    let rowRanges: [Range<Int>]
}
