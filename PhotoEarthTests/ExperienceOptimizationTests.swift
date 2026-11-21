import Foundation
import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct ExperienceOptimizationTests {
    private func place(_ id: String, latitude: Double, longitude: Double, date: Double) -> TravelPlace {
        TravelPlace(id: id, name: id, country: nil, coordinate: .init(latitude: latitude, longitude: longitude),
                    startDate: Date(timeIntervalSince1970: date), endDate: Date(timeIntervalSince1970: date),
                    photoCount: 1, coverAssetID: nil)
    }

    @Test func oldContinentReceivesBudgetEvenWithHundredsOfRecentPlaces() {
        var recent: [TravelPlace] = []
        for i in 0..<300 {
            let latitude = Double(i / 30) * 2
            let longitude = Double(i % 30) * 2
            recent.append(place("new-\(i)", latitude: latitude, longitude: longitude, date: Double(i + 100)))
        }
        let old = place("old-continent", latitude: -32, longitude: 145, date: 0)
        let index = MapPlaceSpatialIndex(places: recent + [old])
        let world = index.representatives()
        #expect(world.count == 180)
        #expect(world.contains { $0.id == old.id })
        let region = EarthViewport(center: old.coordinate, angularRadius: 12)
        #expect(index.representatives(in: region).map(\.id) == [old.id])
        #expect(MapPlaceSpatialIndex(places: (recent + [old]).reversed()).representatives() == world)
    }

    @Test func regionalMarkersRespectDensityAndPreferredPhotoEvenAtDateLine() {
        let places = (0..<50).map { place("dense-\($0)", latitude: 10, longitude: $0.isMultiple(of: 2) ? -180 : 180, date: Double($0)) }
        let index = MapPlaceSpatialIndex(places: places)
        let result = index.representatives(in: .init(center: .init(latitude: 10, longitude: 179), angularRadius: 10),
                                          preferredPlaceID: "dense-0")
        #expect(result.count == 2)
        #expect(result.first?.id == "dense-0")
        #expect(index.representatives(limit: 0).isEmpty)
        let smallMovementNeedsRefresh = MapPlaceSpatialIndex.needsRefresh(
            from: EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 40),
            to: EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0.5), angularRadius: 40))
        #expect(smallMovementNeedsRefresh == false)
    }

    @Test func aVisibleOlderPlaceSurvivesNewerOffscreenPlacesInItsCell() {
        let old = place("visible-old", latitude: 0.1, longitude: 0.1, date: 0)
        let recent = (0..<1_000).map {
            place("outside-\($0)", latitude: 1.9, longitude: 1.9, date: Double($0 + 1))
        }
        let viewport = EarthViewport(center: old.coordinate, angularRadius: 1)
        let index = MapPlaceSpatialIndex(places: recent + [old])
        #expect(index.representatives(in: viewport).map(\.id) == [old.id])
        #expect(index.representatives().count == 2)
    }

    @Test func markerRefreshHasAnExplicitMovementAndScaleThreshold() {
        let old = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 40)
        let small = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0.5), angularRadius: 40)
        let moved = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 7), angularRadius: 40)
        let zoomed = EarthViewport(center: old.center, angularRadius: 20)
        let stays = MapPlaceSpatialIndex.needsRefresh(from: old, to: small)
        let moves = MapPlaceSpatialIndex.needsRefresh(from: old, to: moved)
        let zooms = MapPlaceSpatialIndex.needsRefresh(from: old, to: zoomed)
        #expect(stays == false)
        #expect(moves == true)
        #expect(zooms == true)
    }

    @Test @MainActor func aStationaryContentRevisionKeepsItsRegionalMarkerBudget() async throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: 0)
        let camera = GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 0), distance: 800_000)
        let source = [place("near", latitude: 0, longitude: 0, date: 0),
                      place("far", latitude: 55, longitude: 130, date: 10)]
        var snapshots = 0
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in snapshots += 1 },
                                                      onUserLocationUpdate: { _ in })
        defer { coordinator.cancelPendingSnapshot() }
        func update(revision: Int, preferred: String? = nil) {
            coordinator.update(map, places: source, horizontalPresentationOffset: 0,
                               contentRevision: revision, camera: camera, isManipulating: false,
                               showsUserLocation: false, settleRevision: 0, preferredPlaceID: preferred,
                               onViewportSettled: { _ in snapshots += 1 }, onUserLocationUpdate: { _ in })
        }
        update(revision: 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while snapshots == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(snapshots == 1)
        #expect(map.annotations.count == 1)
        update(revision: 2)
        #expect(map.annotations.count == 1, "An unchanged camera must not receive offscreen global markers")
        // Preferred-only changes reuse the index but must still update selection.
        update(revision: 2, preferred: "far")
        #expect(map.annotations.count == 2)
        update(revision: 2)
        #expect(map.annotations.count == 1)
        #expect(snapshots == 1, "Marker content refresh must not restart photo-strip delivery")
    }

    @Test func cityMembershipIsAppliedBeforePreviewSampleBudget() {
        let records = (0..<200).map { i in
            PhotoAssetRecord(id: "photo-\(i)", coordinate: .init(latitude: 0, longitude: 0),
                             creationDate: Date(timeIntervalSince1970: Double(i)),
                             pixelWidth: 1920, pixelHeight: 1080, isFavorite: false,
                             placeID: i == 0 ? "city" : "nearby")
        }
        let result = PhotoSpatialIndex(records: records).photos(in: .init(center: .init(latitude: 0, longitude: 0), angularRadius: 10),
                                                              limit: 144, placeIDs: ["city"])
        #expect(result.map(\.id) == ["photo-0"])
    }

    @Test @MainActor func previewFailureCannotBePresentedAsAnEmptySuccessfulBatch() async throws {
        enum Failure: Error { case unavailable }
        let model = GlobeExperienceModel()
        defer { model.deactivate() }
        let viewport = EarthViewport(center: .init(latitude: 0, longitude: 0), angularRadius: 40)
        model.activate(initialCenter: viewport.center) { _, _ in throw Failure.unavailable }
        model.receiveViewport(PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in true }))
        for _ in 0..<150 {
            if model.photoQueryFailed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.photoQueryFailed)
        #expect(!model.photoBatchReady && !model.isRefreshingPhotos && model.visiblePhotos.isEmpty)
        model.refreshPhotos()
        #expect(!model.photoQueryFailed)
    }

    @Test @MainActor func scopeButtonParticipatesInNativeDockOrderOnlyInCityMode() {
        let navigation = ZoomButtonFocusNavigation()
        navigation.includesCurrentView = true
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.currentControl == .currentView)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.currentControl == .currentView)
        navigation.moveFocus(for: .leftArrow)
        #expect(navigation.currentControl == .zoomIn)
        navigation.includesCurrentView = false
        navigation.didFocus(.zoomIn)
        navigation.moveFocus(for: .rightArrow)
        #expect(navigation.currentControl == .zoomIn)
    }
}
