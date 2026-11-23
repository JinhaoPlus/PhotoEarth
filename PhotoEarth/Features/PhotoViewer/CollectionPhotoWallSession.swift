import Foundation
import Observation

@MainActor @Observable final class CollectionPhotoWallSession {
    private(set) var records: [PhotoAssetRecord] = []
    private(set) var nextOffset: Int? = 0
    private(set) var isLoading = false
    private(set) var pagingError: String?
    private(set) var totalPhotoCount: Int?
    private(set) var countErrorMessage: String?
    private(set) var membership: Membership?
    private(set) var journeys: [Journey] = []
    var visibleJourneys: [Journey] { journeys.filter { $0.page.totalPhotoCount != 0 } }

    @MainActor @Observable final class Journey: Identifiable {
        static let previewLimit = 5
        let collection: PlaceCollection
        let page: CollectionPhotoWallSession
        var isExpanded = false
        var id: String { collection.id }

        init(collection: PlaceCollection, city: Membership) {
            self.collection = collection
            page = CollectionPhotoWallSession()
            page.membership = Membership(reader: city.reader, places: city.places, placeIDs: collection.placeIDs,
                                         matchingVisits: collection.places, photoCount: collection.photoCount,
                                         reviewOrigin: .collection(placeIDs: collection.placeIDs, in: collection.places))
            page.totalPhotoCount = collection.photoCount
        }

        func load(app: AppModel, limit: Int = PhotoWallPageSelection.pageSize) {
            page.loadMore(app: app, collection: collection, limit: limit)
        }
    }

    struct Membership {
        let reader: SQLiteTravelIndexStore?
        let places: PhotoWallPlaces
        let placeIDs: [String]
        let matchingVisits: [TravelPlace]
        let photoCount: Int
        let reviewOrigin: MapReviewOrigin?
    }

    @ObservationIgnored private var recordIDs = Set<String>()
    @ObservationIgnored private(set) var excludedAssetIDs = Set<String>()
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?

    func loadMore(app: AppModel, collection: PlaceCollection, limit: Int = PhotoWallPageSelection.pageSize) {
        guard !isLoading, let offset = nextOffset else { return }
        isLoading = true
        pagingError = nil
        pageTask = Task { @MainActor in
            do {
                if membership == nil {
                    let reader = try await app.makePhotoReadSnapshot()
                    let summaries = try await reader?.placeSummariesForReading() ?? app.index?.places ?? []
                    let ids = try collection.matchingPlaceIDs(in: summaries)
                    try Task.checkCancellation()
                    let members = Set(ids)
                    let visits = summaries.filter { members.contains($0.id) }
                    let cityMembership = Membership(reader: reader, places: PhotoWallPlaces(summaries),
                                                    placeIDs: ids, matchingVisits: visits,
                                                    photoCount: visits.reduce(0) { $0 + $1.photoCount },
                                                    reviewOrigin: .collection(placeIDs: ids, in: summaries))
                    if collection.groupsPhotosByJourney {
                        let trips = try await reader?.journeysForReading() ?? app.index?.journeys ?? []
                        try Task.checkCancellation()
                        let scopedCity = PlaceCollection(id: collection.id, title: collection.title,
                                                         subtitle: collection.subtitle, places: visits)
                        journeys = scopedCity.journeySegments(in: trips).map { Journey(collection: $0, city: cityMembership) }
                    }
                    membership = cityMembership
                    excludedAssetIDs.formUnion(app.excludedAssetIDs)
                    refreshCount(app: app)
                    if collection.groupsPhotosByJourney {
                        nextOffset = nil
                        isLoading = false
                        return
                    }
                }
                guard let membership else { return }
                var cursor = offset
                let previousRecordCount = records.count
                while true {
                    let page = try await app.photoPage(for: membership.placeIDs, offset: cursor,
                                                       limit: limit, reader: membership.reader)
                    try Task.checkCancellation()
                    exclude(app.excludedAssetIDs, app: app)
                    records.append(contentsOf: page.records.filter {
                        !excludedAssetIDs.contains($0.id) && recordIDs.insert($0.id).inserted
                    })
                    nextOffset = page.nextOffset
                    guard records.count == previousRecordCount, let next = page.nextOffset, next > cursor else { break }
                    cursor = next
                    await Task.yield()
                    try Task.checkCancellation()
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let selectionError = error as? PhotoWallSelectionError {
                    nextOffset = nil
                    pagingError = selectionError.localizedDescription
                } else {
                    pagingError = AppLocalization.string("error.wall.index", defaultValue: "The photo index is temporarily unavailable. Try again.")
                }
            }
            isLoading = false
        }
    }

    func exclude(_ assetIDs: Set<String>, app: AppModel) {
        let newlyExcluded = assetIDs.subtracting(excludedAssetIDs)
        guard !newlyExcluded.isEmpty else { return }
        // Membership stays fixed while browsing. Revocations apply immediately;
        // newly available assets can enter a fresh session when the wall reopens.
        excludedAssetIDs.formUnion(newlyExcluded)
        for journey in journeys where journey.page.nextOffset != 0 || journey.page.isLoading {
            journey.page.exclude(newlyExcluded, app: app)
        }
        records.removeAll { newlyExcluded.contains($0.id) }
        recordIDs.subtract(newlyExcluded)
        refreshCount(app: app)
    }

    func refreshCount(app: AppModel) {
        guard let membership else { return }
        countTask?.cancel()
        countErrorMessage = nil
        let excluded = excludedAssetIDs
        if excluded.isEmpty {
            totalPhotoCount = membership.photoCount
            return
        }
        totalPhotoCount = nil
        countTask = Task { @MainActor in
            do {
                let removedCount = try await app.removedPhotoCount(for: Set(membership.placeIDs), assetIDs: excluded,
                                                                  reader: membership.reader)
                try Task.checkCancellation()
                totalPhotoCount = membership.photoCount - removedCount
            } catch {
                guard !Task.isCancelled else { return }
                countErrorMessage = AppLocalization.string("error.wall.count", defaultValue: "Couldn’t count all items.")
            }
        }
    }

    func cancel() {
        for journey in journeys { journey.page.cancel() }
        journeys = []
        pageTask?.cancel()
        countTask?.cancel()
        pageTask = nil
        countTask = nil
        membership = nil
    }
}
