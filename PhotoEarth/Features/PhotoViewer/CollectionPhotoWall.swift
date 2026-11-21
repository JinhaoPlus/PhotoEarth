import SwiftUI
import UIKit

struct CollectionPhotoWall: View {
    @ObservedObject var model: AppModel
    let collection: PlaceCollection
    let controlGlobe: @MainActor @Sendable (EarthSlideshowCameraTarget, Bool) -> Void
    let restoreGlobe: () -> Void
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = CollectionPhotoWallSession()
    @State private var focusedPhotoID: String?
    @State private var selectedPhoto: PhotoAssetRecord?
    @State private var preview: UIImage?
    @State private var resolvedLabels: [String: PlaceDisplayLabel] = [:]
    @State private var slideshow: EarthSlideshowCoordinator?
    @State private var mapReviewOrigin: MapReviewOrigin?

    private func placeLabel(_ id: String) -> PlaceDisplayLabel? {
        guard let place = session.membership?.places[id] else { return nil }
        let stored = PlaceDisplayLabel(place: place)
        if stored.isComplete { return stored }
        if let current = model.indexedPlaces[id], current.coordinate == place.coordinate {
            let label = PlaceDisplayLabel(place: current)
            if label.isComplete { return label }
        }
        return resolvedLabels[id] ?? stored
    }

    var body: some View {
        ZStack {
            ViewportPhotoWall(records: session.records, isLoading: session.isLoading, hasMore: session.nextOffset != nil,
                              placeLabel: placeLabel, selectPhoto: { photo, image in
                                  selectedPhoto = photo
                                  preview = image
                              }, loadMore: loadMore, close: close,
                              isActive: selectedPhoto == nil && slideshow == nil && mapReviewOrigin == nil,
                              selectedPhotoID: $focusedPhotoID, errorMessage: session.pagingError,
                              title: collection.title,
                              canRetry: session.nextOffset != nil,
                              emptyHint: nil,
                              totalPhotoCount: session.totalPhotoCount,
                              countErrorMessage: session.countErrorMessage,
                              retryPhotoCount: { session.refreshCount(app: model) },
                              showsPhotoPlaceNames: !collection.representsSingleCity,
                              startSlideshow: startSlideshow,
                              openMapReview: { mapReviewOrigin = session.membership?.reviewOrigin },
                              canOpenMapReview: session.membership?.reviewOrigin != nil,
                              labelStates: model.placeLabelStates,
                              resolvePlaceLabels: resolveLabels)
                .opacity(slideshow == nil && mapReviewOrigin == nil ? 1 : 0)
                .disabled(selectedPhoto != nil || slideshow != nil || mapReviewOrigin != nil)
                .accessibilityHidden(selectedPhoto != nil || slideshow != nil || mapReviewOrigin != nil)
            if let mapReviewOrigin {
                MapReviewView(app: model, origin: mapReviewOrigin, reader: session.membership?.reader,
                              controlGlobe: controlGlobe, restoreGlobe: restoreGlobe) {
                    self.mapReviewOrigin = nil
                }
                .zIndex(3)
            }
            if let photo = selectedPhoto {
                PhotoDetailView(record: photo, placeLabel: photo.placeID.flatMap(placeLabel),
                                initialImage: preview,
                                labelState: photo.placeID.flatMap { model.placeLabelStates[$0] },
                                resolvePlaceLabel: { await resolveLabels([photo.placeID].compactMap { $0 }) },
                                records: session.records,
                                hasMorePhotos: session.nextOffset != nil,
                                isLoadingMorePhotos: session.isLoading,
                                pagingError: session.pagingError,
                                loadMorePhotos: loadMore,
                                selectRecord: { next in
                                    selectedPhoto = next
                                    focusedPhotoID = next.id
                                    preview = nil
                                },
                                locationLibrary: model) {
                    selectedPhoto = nil
                    preview = nil
                }
            }
            if let slideshow {
                EarthSlideshowView(coordinator: slideshow) {
                    finishSlideshow()
                }
                .zIndex(4)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
        .task(id: collection.id) {
            session.cancel()
            session = CollectionPhotoWallSession()
            resolvedLabels = [:]; focusedPhotoID = nil
            slideshow?.cancel(); slideshow = nil
            selectedPhoto = nil; preview = nil
            mapReviewOrigin = nil
            loadMore()
        }
        .onDisappear {
            session.cancel()
            slideshow?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preview = nil } }
        .onChange(of: model.excludedAssetIDs) { previous, removed in
            slideshow?.removeAssets(removed.subtracting(previous))
            session.exclude(removed, app: model)
            if let photo = selectedPhoto, removed.contains(photo.id) { selectedPhoto = nil; preview = nil }
        }
    }

    private func loadMore() {
        session.loadMore(app: model, collection: collection)
    }

    private func resolveLabels(_ ids: [String]) async {
        let currentSession = session
        guard let places = currentSession.membership?.places else { return }
        let result = await model.resolveSnapshotLabels(for: ids, places: places)
        guard !Task.isCancelled, session === currentSession, currentSession.membership != nil else { return }
        resolvedLabels.merge(result) { _, latest in latest }
    }

    private func startSlideshow() {
        guard slideshow == nil, selectedPhoto == nil, mapReviewOrigin == nil,
              let membership = session.membership, !membership.matchingVisits.isEmpty else { return }
        let scope = EarthSlideshowScope(
            id: collection.id,
            title: collection.title,
            kind: slideshowScopeKind
        )
        let coordinator = model.makeEarthSlideshow(scope: scope, places: membership.matchingVisits,
                                                   reader: membership.reader, collectionExclusions: session.excludedAssetIDs,
                                                   reduceMotion: reduceMotion,
                                                   cameraAction: controlGlobe)
        slideshow = coordinator
        coordinator.start(waitingForConfirmation: true)
    }

    private var slideshowScopeKind: EarthSlideshowScope.Kind {
        switch collection.scope {
        case .country: .country
        case .city: .city
        case .visits:
            collection.places.count == 1 ? .recentVisit
                : (collection.representsSingleCity ? .city : .collection)
        }
    }

    private func finishSlideshow() {
        slideshow = nil
        restoreGlobe()
    }
}
