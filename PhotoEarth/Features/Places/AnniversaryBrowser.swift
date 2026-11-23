import SwiftUI

/// Each interaction checks the same dated ranges and read transaction used to draw the shelves.
struct AnniversaryAccessRequest {
    let title: String
    let ranges: [Range<Date>]
    let reader: SQLiteTravelIndexStore?
    let isCurrent: () -> Bool
    let open: () -> Void

    @MainActor func journey(in model: AppModel, chosen: String) async throws -> String? {
        guard let index = model.index else { throw TravelIndexStoreError.invalidSnapshot }
        var journey: String?
        for range in ranges {
            let scope = try await index.journeyScope(chosen: chosen, excluding: model.excludedAssetIDs) { offset in
                try await model.anniversaryPage(in: range, reader: reader, offset: offset, excluding: model.excludedAssetIDs)
            }
            switch scope {
            case .empty: continue
            case .requiresUnlock: return nil
            case .journey(let id):
                guard journey == nil || journey == id else { return nil }
                journey = id
            }
        }
        return journey
    }
}

struct AnniversaryShelf: Identifiable {
    let id: Int
    let range: Range<Date>?
    var records: [PhotoAssetRecord] = []
    var visitIDs: [String] = []
    var nextOffset: Int?
    var expanded = false
    var loading = false
    var failed = false

    func locationLabels(in places: PhotoWallPlaces) -> [PlaceDisplayLabel] {
        var labels: [PlaceDisplayLabel] = []
        var displayed = Set<String>()
        for id in visitIDs {
            guard let place = places[id] else { continue }
            let label = PlaceDisplayLabel(place: place)
            guard let name = label.hasCity ? label.compactName : label.displayCountry,
                  displayed.insert(name).inserted else { continue }
            labels.append(label)
            if labels.count == 3 { break }
        }
        return labels
    }
}

@MainActor @Observable final class AnniversaryBrowser {
    let reader: SQLiteTravelIndexStore?
    let excluded: Set<String>
    var shelves: [AnniversaryShelf]
    private let model: AppModel

    init(model: AppModel, reader: SQLiteTravelIndexStore?, shelves: [AnniversaryShelf]) {
        self.model = model
        self.reader = reader
        self.shelves = shelves
        excluded = model.excludedAssetIDs
    }

    func load(_ index: Int, preview: Bool = false) async throws {
        guard let range = shelves[index].range, !shelves[index].loading,
              let offset = shelves[index].nextOffset else { return }
        shelves[index].loading = true
        defer { shelves[index].loading = false }
        do {
            let page = try await model.anniversaryPage(in: range, reader: reader, offset: offset, excluding: excluded,
                                                       limit: preview ? 5 : PhotoWallPageSelection.pageSize)
            if preview, !page.records.isEmpty {
                if page.nextOffset == nil {
                    shelves[index].visitIDs = page.records.compactMap(\.placeID)
                } else {
                    shelves[index].visitIDs = try await model.anniversaryVisitIDs(in: range, reader: reader, excluding: excluded)
                }
            }
            try Task.checkCancellation()
            shelves[index].records += page.records
            shelves[index].nextOffset = page.nextOffset
            shelves[index].failed = false
        } catch {
            if !Task.isCancelled { shelves[index].failed = true }
            throw error
        }
    }

    func snapshot() async throws -> SlideshowSnapshot {
        let occupied = shelves.filter { !$0.records.isEmpty }
        let chapters = occupied.compactMap { shelf -> TravelPlace? in
            guard let first = shelf.records.first else { return nil }
            return TravelPlace(id: "anniversary-\(shelf.id)", name: String(shelf.id), coordinate: first.coordinate,
                               startDate: first.creationDate, endDate: first.creationDate, photoCount: 1, coverAssetID: first.id)
        }
        let snapshot = try SlideshowSnapshot(places: chapters)
        for (shelf, chapter) in zip(occupied, chapters) {
            guard let range = shelf.range else { continue }
            var next: Int? = 0
            while let offset = next {
                try Task.checkCancellation()
                let page = try await model.anniversaryPage(in: range, reader: reader, offset: offset, excluding: excluded)
                try await snapshot.appendBatch(page.records, visitID: chapter.id)
                next = page.nextOffset
            }
        }
        return snapshot
    }
}

@MainActor @Observable final class AnniversaryDetailSelection: Identifiable {
    let browser: AnniversaryBrowser
    let index: Int
    var record: PhotoAssetRecord
    var preview: UIImage?

    init(browser: AnniversaryBrowser, index: Int, record: PhotoAssetRecord, preview: UIImage?) {
        self.browser = browser
        self.index = index
        self.record = record
        self.preview = preview
    }
}

struct AnniversaryPhotoDetail: View {
    let selection: AnniversaryDetailSelection
    let model: AppModel
    let close: () -> Void

    var body: some View {
        let browser = selection.browser
        let index = selection.index
        let shelf = browser.shelves[index]
        let record = selection.record
        PhotoDetailView(record: record, placeLabel: record.placeID.flatMap { model.indexedPlaces[$0].map(PlaceDisplayLabel.init(place:)) },
                        initialImage: selection.preview, records: shelf.records, hasMorePhotos: shelf.nextOffset != nil,
                        isLoadingMorePhotos: shelf.loading, pagingError: shelf.failed ? String(localized: "error.wall.index") : nil,
                        loadMorePhotos: { Task { try? await browser.load(index) } },
                        selectRecord: { next in
                            selection.record = next
                            selection.preview = nil
                            if !shelf.records.prefix(5).contains(where: { $0.id == next.id }) { browser.shelves[index].expanded = true }
                        }, locationLibrary: model, close: close)
            .ignoresSafeArea()
    }
}
