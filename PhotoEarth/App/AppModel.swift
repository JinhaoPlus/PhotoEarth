import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case welcome
        case scanning
        case globe
        case empty
        case denied
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var index: TravelIndex?
    @Published var selectedPlaceID: String?
    @Published var isShowingGallery = false
    @Published private(set) var isUsingSampleData = false

    private let photoLibrary: any PhotoLibraryProviding
    private let indexStore: any TravelIndexStoring
    private let preferencesStore: any PreferenceSyncing
    private let clusterer: TravelClusterer
    private var preferences = SyncedPreferences()
    private var samplePhotos: [PhotoAssetRecord] = []
    private var samplePhotoIndex: PhotoSpatialIndex?

    init() {
        self.photoLibrary = PhotoKitLibrary()
        self.indexStore = SQLiteTravelIndexStore()
#if DEBUG
        self.preferencesStore = LocalPreferenceStore()
#else
        self.preferencesStore = ICloudPreferenceStore()
#endif
        self.clusterer = TravelClusterer()
    }

    init(
        photoLibrary: any PhotoLibraryProviding,
        indexStore: any TravelIndexStoring,
        preferencesStore: any PreferenceSyncing,
        clusterer: TravelClusterer
    ) {
        self.photoLibrary = photoLibrary
        self.indexStore = indexStore
        self.preferencesStore = preferencesStore
        self.clusterer = clusterer
    }

    var selectedPlace: TravelPlace? {
        index?.place(id: selectedPlaceID) ?? index?.places.first
    }

    func start() async {
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            useSampleData()
            return
        }
        preferences = await preferencesStore.load()
        if let cached = try? await indexStore.load(), !cached.places.isEmpty {
            apply(cached, usingSampleData: false)
            return
        }

        let status = await photoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            await scan()
        case .notDetermined:
            phase = .welcome
        case .denied, .restricted:
            phase = .denied
        }
    }

    func requestAccessAndScan() async {
        phase = .scanning
        let status = await photoLibrary.requestAuthorization()
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }
        await scan()
    }

    func rescan() async {
        guard !isUsingSampleData else {
            phase = .welcome
            index = nil
            selectedPlaceID = nil
            samplePhotos = []
            samplePhotoIndex = nil
            return
        }
        await scan()
    }

    func useSampleData() {
        let snapshot = SampleTravelIndex.make()
        samplePhotos = snapshot.photos
        samplePhotoIndex = PhotoSpatialIndex(records: snapshot.photos)
        apply(snapshot.index, usingSampleData: true)
    }

    func photos(in viewport: EarthViewport, limit: Int) async -> [PhotoAssetRecord] {
        if let samplePhotoIndex {
            return samplePhotoIndex.photos(in: viewport, limit: limit)
        }
        return (try? await indexStore.photos(in: viewport, limit: limit)) ?? []
    }

    func photoPage(
        in viewport: EarthViewport,
        offset: Int,
        limit: Int
    ) async -> PhotoQueryPage {
        if isUsingSampleData {
            let matching = samplePhotos
                .filter {
                    GlobeMath.angularDistanceDegrees(
                        from: viewport.center,
                        to: $0.coordinate
                    ) <= viewport.angularRadius
                }
                .sorted {
                    if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                    return $0.creationDate > $1.creationDate
                }
            let start = min(max(0, offset), matching.count)
            let end = min(start + max(0, limit), matching.count)
            return PhotoQueryPage(
                records: Array(matching[start..<end]),
                nextOffset: end < matching.count ? end : nil
            )
        }
        return (try? await indexStore.photoPage(
            in: viewport,
            offset: offset,
            limit: limit
        )) ?? PhotoQueryPage(records: [], nextOffset: nil)
    }

    func latestAssetID(for place: TravelPlace) async -> String? {
        guard place.photoCount > 0 else { return place.coverAssetID }
        if isUsingSampleData {
            return samplePhotos
                .filter { $0.placeID == place.id }
                .sorted {
                    if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                    return $0.creationDate > $1.creationDate
                }
                .first?.id ?? place.coverAssetID
        }
        return (try? await indexStore.latestAssetID(for: place.id)) ?? place.coverAssetID
    }

    func assetIDs(for placeID: String, offset: Int, limit: Int) async -> [String] {
        if isUsingSampleData {
            return samplePhotos
                .filter { $0.placeID == placeID }
                .sorted {
                    if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                    return $0.creationDate < $1.creationDate
                }
                .dropFirst(max(0, offset))
                .prefix(max(0, limit))
                .map(\.id)
        }
        return (try? await indexStore.assetIDs(
            for: placeID,
            offset: offset,
            limit: limit
        )) ?? []
    }

    func applyResolvedPlaceLabels(_ labels: [String: PlaceDisplayLabel]) async {
        guard !isUsingSampleData, !labels.isEmpty, var updatedIndex = index else { return }
        var changedPlaces: [TravelPlace] = []

        for position in updatedIndex.places.indices {
            let placeID = updatedIndex.places[position].id
            guard let label = labels[placeID], !label.city.isEmpty else { continue }
            let existing = updatedIndex.places[position]
            guard existing.name != label.city || existing.country != label.country else { continue }
            updatedIndex.places[position].name = label.city
            updatedIndex.places[position].country = label.country
            changedPlaces.append(updatedIndex.places[position])
        }

        guard !changedPlaces.isEmpty else { return }
        index = updatedIndex
        try? await indexStore.updatePlaceNames(changedPlaces)
    }

    func select(placeID: String) {
        selectedPlaceID = placeID
        preferences.lastSelectedPlaceID = placeID
        let value = preferences
        Task { await preferencesStore.save(value) }
    }

    func moveSelection(by offset: Int) {
        guard let places = index?.places, !places.isEmpty else { return }
        let current = places.firstIndex { $0.id == selectedPlaceID } ?? 0
        let destination = (current + offset + places.count) % places.count
        select(placeID: places[destination].id)
    }

    private func scan() async {
        phase = .scanning
        do {
            let scan = try await photoLibrary.scanLocatedPhotos()
            let snapshot = clusterer.makeIndex(
                records: scan.locatedPhotos,
                sourcePhotoCount: scan.sourcePhotoCount
            )
            guard !snapshot.index.places.isEmpty else {
                index = snapshot.index
                phase = .empty
                return
            }
            try await indexStore.save(snapshot)
            samplePhotos = []
            samplePhotoIndex = nil
            apply(snapshot.index, usingSampleData: false)
        } catch is CancellationError {
            phase = .welcome
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(_ newIndex: TravelIndex, usingSampleData: Bool) {
        index = newIndex
        isUsingSampleData = usingSampleData
        selectedPlaceID = newIndex.place(id: preferences.lastSelectedPlaceID)?.id
            ?? newIndex.places.first?.id
        phase = .globe
    }
}
