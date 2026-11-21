import Foundation
import Observation

@Observable @MainActor final class OverviewPlaceItem: Identifiable {
    let id: String
    var place: TravelPlace
    var thumbnail: OverviewThumbnail?
    var coverFailed = false
    @ObservationIgnored var latestAssetID: String?
    @ObservationIgnored var previewMetadata: PhotoPreviewMetadata?
    @ObservationIgnored var coverPrepared = false
    @ObservationIgnored var displayedBeforeRefresh: String?
    @ObservationIgnored var scenicPrepared = false
    init(_ place: TravelPlace) { id = place.id; self.place = place }
}

@MainActor struct OverviewPlaceShelf: Identifiable {
    let id: String
    let year: Int
    let showsYearHeading: Bool
    let items: [OverviewPlaceItem]
}

/// Only structural changes publish row arrays. Image/label changes live on
/// individual objects; focus and the retained return anchor never reach GlobeView.
@Observable @MainActor final class OverviewContentModel {
    private(set) var recent: [OverviewPlaceItem] = []
    private(set) var shelves: [OverviewPlaceShelf] = []
    private(set) var hasMore = false
    private(set) var hiddenTransitPhotoCount = 0
    private(set) var hasVisitsBelowMinimum = false
    @ObservationIgnored private var minimumVisitItems = 1
    private(set) var loadedCount = 0
    private(set) var structureRevision = 0
    private(set) var nearestRecentCoordinate: GeoCoordinate?
    let images: OverviewThumbnailPipeline
    @ObservationIgnored var restoredFocusID: String?
    @ObservationIgnored private var allPlaces: [TravelPlace] = []
    @ObservationIgnored private var source: [TravelPlace] = []
    @ObservationIgnored private var items: [OverviewPlaceItem] = []
    @ObservationIgnored private var lookup: [String: OverviewPlaceItem] = [:]
    @ObservationIgnored private var positions: [String: Int] = [:]
    @ObservationIgnored private var shelfPositions: [String: Int] = [:]
    @ObservationIgnored private var shelfRanges: [Range<Int>] = []
    @ObservationIgnored private var presentationYears: [String: Int] = [:]
    @ObservationIgnored private var visible: Set<String> = []
    @ObservationIgnored private var focusID: String?
    @ObservationIgnored private var direction = 1
    @ObservationIgnored private var imageItemIDs: Set<String> = []
    @ObservationIgnored private var moving = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var lastIndexDate: String?
    @ObservationIgnored private var pendingIndex: TravelIndex?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var coverBatchCount = 0
    @ObservationIgnored private var coverRetryAfter: TimeInterval = 0
    @ObservationIgnored private var hasPendingCovers = false
    @ObservationIgnored private var labelTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let latestCovers: ([TravelPlace]) async throws -> [String: PhotoPreviewMetadata]
    @ObservationIgnored private let resolveLabels: ([String]) async -> Void
    typealias SavedCovers = ([TravelPlace], [String: String]) async -> [String: PhotoPreviewMetadata]
    @ObservationIgnored private let savedCovers: SavedCovers?
    @ObservationIgnored private let scenicCover: ((TravelPlace, PhotoPreviewMetadata?) async -> PhotoPreviewMetadata?)?
    @ObservationIgnored private var scenicTasks: [String: Task<Void, Never>] = [:]

    init(images: OverviewThumbnailPipeline? = nil,
         latestCovers: @escaping ([TravelPlace]) async throws -> [String: PhotoPreviewMetadata],
         resolveLabels: @escaping ([String]) async -> Void = { _ in },
         savedCovers: SavedCovers? = nil,
         scenicCover: ((TravelPlace, PhotoPreviewMetadata?) async -> PhotoPreviewMetadata?)? = nil) {
        self.images = images ?? OverviewThumbnailPipeline()
        self.latestCovers = latestCovers
        self.resolveLabels = resolveLabels
        self.savedCovers = savedCovers
        self.scenicCover = scenicCover
    }

    convenience init(app: AppModel) {
        self.init(latestCovers: { [weak app] places in try await app?.latestPhotoPreviews(for: places) ?? [:] },
                  resolveLabels: { [weak app] ids in await app?.resolvePlaceLabels(for: ids) },
                  savedCovers: { [weak app] visits, held in await app?.savedVisitCovers(for: visits, keeping: held) ?? [:] },
                  scenicCover: { [weak app] place, fallback in
                      await app?.preferredVisitCover(for: place, fallback: fallback)
                  })
    }

    func receive(_ index: TravelIndex?, minimumVisitItems: Int = 1) {
        let thresholdChanged = self.minimumVisitItems != minimumVisitItems
        self.minimumVisitItems = minimumVisitItems
        hasVisitsBelowMinimum = index?.places.contains { !JourneyVisitThreshold.includes($0, minimum: minimumVisitItems) } ?? false
        hiddenTransitPhotoCount = index?.hiddenTransitPhotoCount ?? 0
        guard let index else {
            resetScenicWork()
            preparation?.cancel(); preparation = nil; generation = UUID(); lastIndexDate = nil; pendingIndex = nil
            labelTasks.values.forEach { $0.cancel() }; labelTasks = [:]
            allPlaces = []; source = []; items = []; lookup = [:]; visible = []; imageItemIDs = []; restoredFocusID = nil
            presentationYears = [:]
            nearestRecentCoordinate = nil
            hasPendingCovers = false
            images.invalidate(nil); publishRows()
            return
        }
        guard thresholdChanged || lastIndexDate != index.contentRevision else { return }
        resetScenicWork()
        lastIndexDate = index.contentRevision
        coverBatchCount = 0
        coverRetryAfter = 0
        hasPendingCovers = true
        preparation?.cancel(); preparation = nil; generation = UUID()
        labelTasks.values.forEach { $0.cancel() }; labelTasks = [:]
        if active, !items.isEmpty, !thresholdChanged {
            pendingIndex = index
            let current = Dictionary(uniqueKeysWithValues: index.places.map { ($0.id, $0) })
            allPlaces = allPlaces.compactMap { old in
                guard let new = current[old.id], new.coordinate == old.coordinate else { return nil }
                return new
            }
            rebuildRepresentatives(metadataMayHaveChanged: true, alwaysPublish: true,
                                   resetsPresentationYears: false)
        } else {
            pendingIndex = nil
            applyStructure(index)
        }
        prepareMore()
    }

    private func applyStructure(_ index: TravelIndex) {
        hasPendingCovers = true
        let interval = OverviewPerformance.begin("Home structure")
        defer { OverviewPerformance.end("Home structure", interval) }
        allPlaces = index.places.sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate > $1.endDate }
        rebuildRepresentatives(metadataMayHaveChanged: true, alwaysPublish: true,
                               resetsPresentationYears: true)
    }

    private func rebuildRepresentatives(metadataMayHaveChanged: Bool, alwaysPublish: Bool,
                                        resetsPresentationYears: Bool) {
        let previousSourceIDs = source.map(\.id)
        let previousItemCount = items.count
        let existing = lookup
        source = PlaceCollection.homeCityRepresentatives(inRecencyOrder: allPlaces, minimumVisitItems: minimumVisitItems)
        // Keep year membership with the current browsing order. Metadata may
        // update a date while active; both regroup together when returning.
        let calendar = Calendar(identifier: .gregorian)
        let previousYears = presentationYears
        presentationYears = Dictionary(uniqueKeysWithValues: source.map {
            ($0.id, resetsPresentationYears
                ? calendar.component(.year, from: $0.endDate)
                : previousYears[$0.id] ?? calendar.component(.year, from: $0.endDate))
        })
        nearestRecentCoordinate = allPlaces.first?.coordinate
        let count = min(source.count, max(15, previousItemCount))
        items = source.prefix(count).map { place in
            if let old = existing[place.id], old.place.coordinate == place.coordinate {
                if metadataMayHaveChanged { updateMetadata(old, to: place) }
                else if old.place != place { old.place = place }
                return old
            }
            return OverviewPlaceItem(place)
        }
        lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        remapRetainedFocus()
        let structureChanged = previousSourceIDs != source.map(\.id)
            || previousItemCount != items.count
        guard alwaysPublish || structureChanged else { return }
        hasPendingCovers = items.contains { !$0.coverPrepared }
        publishRows()
    }

    func updateLabel(_ place: TravelPlace) {
        guard let position = allPlaces.firstIndex(where: { $0.id == place.id && $0.coordinate == place.coordinate }) else {
            if let pendingPosition = pendingIndex?.places.firstIndex(where: { $0.id == place.id && $0.coordinate == place.coordinate }) {
                pendingIndex?.places[pendingPosition] = place
            }
            return
        }
        allPlaces[position] = place
        if let position = pendingIndex?.places.firstIndex(where: { $0.id == place.id && $0.coordinate == place.coordinate }) { pendingIndex?.places[position] = place }
        rebuildRepresentatives(metadataMayHaveChanged: false, alwaysPublish: false,
                               resetsPresentationYears: false)
        prepareMore()
        updateImages()
    }

    private func remapRetainedFocus() {
        let valid = Set(items.map { "place-\($0.id)" })
        focusID = remappedFocusID(focusID, valid: valid)
        restoredFocusID = remappedFocusID(restoredFocusID, valid: valid)
    }

    private func remappedFocusID(_ value: String?, valid: Set<String>) -> String? {
        guard let value, value.hasPrefix("place-"), !valid.contains(value) else { return value }
        let selectedID = String(value.dropFirst("place-".count))
        guard let selected = allPlaces.first(where: { $0.id == selectedID }),
              let replacement = PlaceCollection.city(containing: selected, in: allPlaces).placeIDs
                .map({ "place-\($0)" }).first(where: valid.contains) else { return value }
        return replacement
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value {
            scenicTasks.values.forEach { $0.cancel() }; scenicTasks = [:]
            items.forEach {
                $0.scenicPrepared = false
                $0.displayedBeforeRefresh = nil
                if savedCovers != nil { $0.coverPrepared = false; $0.latestAssetID = nil }
            }
            if savedCovers != nil { hasPendingCovers = true }
            preparation?.cancel(); preparation = nil; generation = UUID()
            labelTasks.values.forEach { $0.cancel() }; labelTasks = [:]
            images.update([:], moving: false)
            for id in imageItemIDs { lookup[id]?.thumbnail = nil }
            imageItemIDs = []
        } else {
            if let pendingIndex { self.pendingIndex = nil; applyStructure(pendingIndex) }
            prepareMore(); updateImages()
        }
    }

    private func updateMetadata(_ item: OverviewPlaceItem, to place: TravelPlace) {
        let unchanged = item.place.coordinate == place.coordinate && item.place.endDate == place.endDate
            && item.place.photoCount == place.photoCount && item.place.coverAssetID == place.coverAssetID
        item.place = place; item.coverPrepared = false
        // Recheck identical counts without blanking an unchanged cover. Edits
        // and removals invalidate separately through PhotoAssetChangeNotice.
        if savedCovers != nil {
            if visible.contains(item.id), let asset = item.latestAssetID { item.displayedBeforeRefresh = asset }
            item.latestAssetID = nil
            item.thumbnail = nil
        }
        if !unchanged { item.latestAssetID = nil; item.previewMetadata = nil; item.thumbnail = nil }
    }

    func expand() {
        guard hasMore else { return }
        let added = source.dropFirst(items.count).prefix(10).map(OverviewPlaceItem.init)
        items.append(contentsOf: added)
        hasPendingCovers = true
        for item in added { lookup[item.id] = item }
        publishRows(); prepareMore()
    }

    private func publishRows() {
        recent = Array(items.prefix(PlaceCollection.homeRecentLimit))
        shelfRanges = recent.isEmpty ? [] : [0..<recent.count]
        var rows: [OverviewPlaceShelf] = []
        var previousYear: Int?
        var start = recent.count
        while start < items.count {
            let year = presentationYears[items[start].id]!
            var end = start + 1
            while end < items.count, end - start < 5, presentationYears[items[end].id] == year {
                end += 1
            }
            rows.append(OverviewPlaceShelf(id: "places-shelf-\(shelfRanges.count)", year: year,
                                           showsYearHeading: previousYear != year, items: Array(items[start..<end])))
            shelfRanges.append(start..<end)
            previousYear = year
            start = end
        }
        shelves = rows
        loadedCount = items.count; hasMore = items.count < source.count
        positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ("place-\($0.element.id)", $0.offset) })
        shelfPositions = Dictionary(uniqueKeysWithValues: shelfRanges.enumerated().flatMap { row, range in
            range.map { ("place-\(items[$0].id)", row) }
        })
        visible.formIntersection(lookup.keys)
        structureRevision += 1
        updateImages()
    }

    private func prepareMore() {
        guard active, hasPendingCovers, preparation == nil, ProcessInfo.processInfo.systemUptime >= coverRetryAfter else { return }
        let token = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, token == self.generation, self.active {
                let batch = Array(self.items.filter { !$0.coverPrepared }.prefix(self.coverBatchCount == 0 ? 15 : 10))
                guard !batch.isEmpty else { self.hasPendingCovers = false; break }
                self.coverBatchCount += 1
                let places = batch.map(\.place)
                let held = Dictionary(uniqueKeysWithValues: batch.compactMap { item in
                    item.displayedBeforeRefresh.map { (item.id, $0) }
                })
                let saved = await self.savedCovers?(places, held) ?? [:]
                guard !Task.isCancelled, token == self.generation, self.active else { return }
                for item in batch {
                    item.displayedBeforeRefresh = nil
                    guard self.lookup[item.id] === item, let selected = saved[item.id] else { continue }
                    item.latestAssetID = selected.assetID
                    item.scenicPrepared = true
                    item.coverPrepared = true
                    item.coverFailed = false
                }
                if !saved.isEmpty { self.updateImages() }

                let misses = batch.filter { !$0.coverPrepared }
                if !misses.isEmpty {
                    do {
                        let covers = try await self.latestCovers(misses.map(\.place))
                        guard !Task.isCancelled, token == self.generation, self.active else { return }
                        for item in misses where self.lookup[item.id] === item {
                            item.previewMetadata = covers[item.id]
                            if self.scenicCover == nil { item.latestAssetID = covers[item.id]?.assetID }
                            item.coverPrepared = true
                            item.coverFailed = false
                        }
                        self.updateImages()
                    } catch {
                        guard !Task.isCancelled, token == self.generation, self.active else { return }
                        OverviewPerformance.event("Home cover batch unavailable")
                        for item in misses { item.coverFailed = true }
                        self.coverRetryAfter = ProcessInfo.processInfo.systemUptime + 60
                        self.preparation = nil
                        return
                    }
                }
                let labelToken = UUID()
                self.labelTasks[labelToken] = Task { [weak self] in
                    await self?.resolveLabels(places.map(\.id))
                    self?.labelTasks.removeValue(forKey: labelToken)
                }
            }
            guard token == self.generation else { return }
            self.preparation = nil
        }
    }

    func focusChanged(_ id: String) {
        guard focusID != id || restoredFocusID != id else { return }
        OverviewPerformance.event("Home focus changed")
        if let old = focusID.flatMap({ shelfPositions[$0] }), let next = shelfPositions[id], old != next {
            direction = next > old ? 1 : -1
        }
        focusID = id; restoredFocusID = id
        if hasMore, let position = positions[id], position >= items.count - 5 {
            expand()
        } else {
            prepareMore()
            updateImages()
        }
    }

    func scrollChanged(moving: Bool) {
        guard self.moving != moving else { return }
        self.moving = moving
        OverviewPerformance.event(moving ? "Home scroll moving" : "Home scroll idle")
        updateImages()
    }

    func visibilityChanged(_ id: String, visible isVisible: Bool) {
        if isVisible {
            guard visible.insert(id).inserted else { return }
        } else {
            guard visible.remove(id) != nil else { return }
        }
        updateImages()
    }

    func coordinate(forFocus id: String?) -> GeoCoordinate? {
        guard let id, let position = positions[id] else { return nil }
        return items[position].place.coordinate
    }

    func validFocusID(_ id: String?) -> String {
        guard let id else { return OverviewFocusHandoff.entryID }
        if id == "home-slideshow" { return id }
        if id == "load-more-places", hasMore { return id }
        return positions[id] != nil ? id : OverviewFocusHandoff.entryID
    }

    func scrollTarget(_ id: String) -> String {
        if let row = shelfPositions[id] { return "places-shelf-\(row)" }
        return id == OverviewFocusHandoff.entryID || id == "home-slideshow" ? "overview-top" : id
    }

    var focusedShelfIndex: Int { focusID.flatMap { shelfPositions[$0] } ?? -1 }

    func isPastRecentDock(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == "load-more-places" || (shelfPositions[id] ?? 0) > 0
    }

    private func updateImages() {
        guard active else { return }
        let focus = focusID ?? restoredFocusID
        let row = focus == "load-more-places" ? shelfRanges.indices.last : focus.flatMap { shelfPositions[$0] }
        let focusPosition = focus.flatMap { positions[$0] }
        let focusRow = row.flatMap { shelfRanges.indices.contains($0) ? shelfRanges[$0] : nil } ?? shelfRanges.first
        let window = OverviewImageWindow.residentIndices(shelfRanges: shelfRanges, focusedShelfIndex: row)
        let visiblePositions = Set(visible.compactMap { positions["place-\($0)"] })
        let resident = OverviewImageWindow.residentIndices(nearby: window, visible: visiblePositions,
                                                          focused: focusPosition)
        let nextIDs = Set(resident.map { items[$0].id })
        for id in imageItemIDs.subtracting(nextIDs) { lookup[id]?.thumbnail = nil }
        imageItemIDs = nextIDs
        var demand: [OverviewImageKey: Int] = [:]
        var preheat: [OverviewImageKey] = []
        var focusedRowOrder: [OverviewImageKey: Int] = [:]
        let predictedRow = max(0, (row ?? 0) + direction)
        for position in resident {
            let item = items[position]
            guard let assetID = item.latestAssetID else {
                if item.thumbnail != nil { item.thumbnail = nil }; continue
            }
            let priority = visible.contains(item.id) ? (focus == "place-\(item.id)" ? 0 : 1) : 2
            let key = OverviewImageKey(assetID: assetID, size: position < PlaceCollection.homeRecentLimit ? .dock : .card,
                                       usesOriginal: scenicCover != nil)
            demand[key] = min(demand[key] ?? 2, priority)
            if let focusRow, focusRow.contains(position), priority < 2 {
                let distance = abs(position - (focusPosition ?? focusRow.lowerBound))
                focusedRowOrder[key] = min(focusedRowOrder[key] ?? distance, distance)
            }
            let thumbnail = images.thumbnail(for: key)
            if item.thumbnail !== thumbnail { item.thumbnail = thumbnail }
            if !key.usesOriginal, priority == 2, shelfPositions["place-\(item.id)"] == predictedRow, preheat.count < 5 {
                preheat.append(key)
            }
        }
        images.update(demand, preheat: preheat, moving: moving, focusedRowOrder: focusedRowOrder)
        let opening = savedCovers != nil && (row ?? 0) == 0 && !moving
            ? Set(items.indices.prefix(PlaceCollection.homeRecentLimit)) : []
        prepareScenicCovers(at: visiblePositions, opening: opening)
    }

    private func prepareScenicCovers(at visiblePositions: Set<Int>, opening: Set<Int>) {
        guard let scenicCover, active else { return }
        let eligible = visiblePositions.union(opening)
        let eligibleIDs = Set(eligible.map { items[$0].id })
        for id in Array(scenicTasks.keys) where !eligibleIDs.contains(id) {
            scenicTasks.removeValue(forKey: id)?.cancel()
        }
        guard !moving else { return }
        for position in eligible.sorted() {
            let item = items[position]
            guard item.coverPrepared, !item.scenicPrepared, scenicTasks[item.id] == nil else { continue }
            let token = generation
            scenicTasks[item.id] = Task { [weak self, weak item] in
                if !opening.contains(position) {
                    do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                }
                guard let self, let item, self.active, !Task.isCancelled else { return }
                guard !self.moving else {
                    self.scenicTasks.removeValue(forKey: item.id)
                    return
                }
                let result = await scenicCover(item.place, item.previewMetadata)
                // A canceled request may finish after a replacement task has
                // claimed this card. It must not remove that task's entry.
                guard !Task.isCancelled else { return }
                guard token == self.generation, self.active,
                      self.lookup[item.id] === item else {
                    self.scenicTasks.removeValue(forKey: item.id)
                    return
                }
                item.scenicPrepared = true
                item.latestAssetID = result?.assetID
                self.scenicTasks.removeValue(forKey: item.id)
                self.updateImages()
            }
        }
    }

    func invalidateImages(changed: Set<String>, removed: Set<String>) {
        resetScenicWork()
        images.invalidate(changed.union(removed), removed: removed)
        if savedCovers != nil {
            preparation?.cancel()
            preparation = nil
            generation = UUID()
            for item in items {
                if visible.contains(item.id), let asset = item.latestAssetID, !removed.contains(asset) {
                    item.scenicPrepared = true
                } else {
                    item.latestAssetID = nil
                    item.thumbnail = nil
                    item.coverPrepared = false
                    hasPendingCovers = true
                }
                if item.displayedBeforeRefresh.map(removed.contains) == true { item.displayedBeforeRefresh = nil }
            }
        }
        for item in items where item.latestAssetID.map(removed.contains) == true {
            item.scenicPrepared = false
            item.displayedBeforeRefresh = nil
            item.latestAssetID = nil; item.thumbnail = nil
        }
        for item in items where item.previewMetadata.map({ removed.contains($0.assetID) }) == true {
            item.previewMetadata = nil
            item.coverPrepared = false
            hasPendingCovers = true
        }
        prepareMore()
        updateImages()
    }

    private func resetScenicWork() {
        scenicTasks.values.forEach { $0.cancel() }; scenicTasks = [:]
        items.forEach { $0.scenicPrepared = false }
    }

    func suspendForBackground() {
        setActive(false); images.invalidate(nil)
    }
}
