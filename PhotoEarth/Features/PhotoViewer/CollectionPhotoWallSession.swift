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

    func loadMore(app: AppModel, collection: PlaceCollection) {
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
                    membership = Membership(reader: reader, places: PhotoWallPlaces(summaries),
                                            placeIDs: ids, matchingVisits: visits,
                                            photoCount: visits.reduce(0) { $0 + $1.photoCount },
                                            reviewOrigin: .collection(placeIDs: ids, in: summaries))
                    excludedAssetIDs.formUnion(app.excludedAssetIDs)
                    refreshCount(app: app)
                }
                guard let membership else { return }
                var cursor = offset
                while true {
                    let page = try await app.photoPage(for: membership.placeIDs, offset: cursor,
                                                       limit: PhotoWallPageSelection.pageSize, reader: membership.reader)
                    try Task.checkCancellation()
                    exclude(app.excludedAssetIDs, app: app)
                    records.append(contentsOf: page.records.filter {
                        !excludedAssetIDs.contains($0.id) && recordIDs.insert($0.id).inserted
                    })
                    nextOffset = page.nextOffset
                    guard records.isEmpty, let next = page.nextOffset, next > cursor else { break }
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
                countErrorMessage = AppLocalization.string("error.wall.count", defaultValue: "Couldn’t count all photos.")
            }
        }
    }

    func cancel() {
        pageTask?.cancel()
        countTask?.cancel()
        pageTask = nil
        countTask = nil
        membership = nil
    }
}
