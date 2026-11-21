import Foundation
import MapKit
import Testing
import UIKit
@testable import PhotoEarth

@MainActor
struct PhotoWallScopeTests {
    @Test func wallExcludesFrontSurfacePhotosOutsideTheActualScreen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let map = makeMap()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = try #require(MapViewportSampler.photoSnapshot(in: map))
        let inside = coordinate(CGPoint(x: 960, y: 540), map)
        let outside = coordinate(CGPoint(x: 960, y: -120), map)
        #expect(snapshot.viewport.contains(outside), "Must reproduce the overly broad old wall selection")
        let source = [photo("outside", outside, time: 200), photo("inside", inside, time: 100)]
        let index = TravelClusterer().makeIndex(records: source)
        try await store.save(index)
        let candidates = try await store.photoWallCandidates(in: snapshot.viewport, offset: 0)
        let page = try await PhotoWallPageSelection.page(from: candidates, offset: 0, limit: 48, snapshot: snapshot)
        #expect(page.records.map(\.id) == ["inside"])
    }

    @Test func changingRegionsUsesTheNewMapAndNeverResurrectsThePreviousWall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let source = [photo("west", GeoCoordinate(latitude: 0, longitude: 20), time: 300),
                      photo("east", GeoCoordinate(latitude: 0, longitude: 140), time: 200),
                      photo("back", GeoCoordinate(latitude: 0, longitude: -100), time: 100)]
        try await store.save(TravelClusterer().makeIndex(records: source))
        let map = makeMap()
        let capture = PhotoWallViewportCapture()
        capture.attach(map)
        var previous: PhotoViewportSnapshot?
        for (longitude, expected) in [(20.0, "west"), (140.0, "east"), (20.0, "west")] {
            capture.release()
            map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: longitude),
                                     fromDistance: GlobeCameraState.regionalDistance, pitch: 0, heading: 0), animated: false)
            try await Task.sleep(for: .milliseconds(50))
            let snapshot = try #require(capture.freeze()?.snapshot)
            #expect(previous?.isCurrent() != true)
            let candidates = try await store.photoWallCandidates(in: snapshot.viewport, offset: 0)
            let page = try await PhotoWallPageSelection.page(from: candidates, offset: 0, limit: 48, snapshot: snapshot)
            #expect(page.records.map(\.id) == [expected])
            previous = snapshot
        }
    }

    @Test func selectFreezesRenderedCameraAgainstUnsubmittedMovement() async throws {
        let map = makeMap()
        let experience = GlobeExperienceModel()
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        defer { coordinator.cancelPendingSnapshot(); experience.deactivate() }
        let rendered = GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 20), distance: GlobeCameraState.regionalDistance)
        func update(_ camera: GlobeCameraState) {
            coordinator.update(map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
                               camera: camera, isManipulating: false, showsUserLocation: false, settleRevision: 0,
                               photoWallViewportCapture: experience.photoWallViewportCapture,
                               onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        }
        update(rendered)
        try await Task.sleep(for: .milliseconds(50))
        experience.transitionCamera(to: GeoCoordinate(latitude: 0, longitude: 140), distance: rendered.distance, animated: false)
        let snapshot = try #require(experience.capturePhotoWallViewport())
        #expect(GlobeMath.angularDistanceDegrees(from: experience.camera.center, to: rendered.center) < 0.01)
        update(GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: -100), distance: rendered.distance))
        #expect(snapshot.isCurrent())
        #expect(snapshot.containsCoordinate(rendered.center))
        experience.resumeDirectManipulation()
        #expect(!snapshot.isCurrent())
        update(GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 140), distance: rendered.distance))
        #expect(abs(map.camera.centerCoordinate.longitude - 140) < 0.01)
    }

    @Test func boundedNativeFilteringPagesPreserveAllMatchesIncludingAfterEmptyPages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let map = makeMap()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = try #require(MapViewportSampler.photoSnapshot(in: map))
        let inside = coordinate(CGPoint(x: 960, y: 540), map)
        let outside = coordinate(CGPoint(x: 960, y: -120), map)
        let source: [PhotoAssetRecord] = (0..<1900).map { (number: Int) in
            let isInside = (600..<850).contains(number) || number == 1800
            let time = Double(2000 - number / 4)
            return photo(String(format: "p-%04d", number), isInside ? inside : outside, time: time)
        }
        try await store.save(TravelClusterer().makeIndex(records: source))
        let expected = source.filter { $0.coordinate == inside }.map(\.id)
        var loaded: [String] = [], offset = 0, emptyPages = 0, didFinish = false
        for _ in 0..<30 {
            let candidates = try await store.photoWallCandidates(in: snapshot.viewport, offset: offset)
            #expect(candidates.records.count <= 512)
            let page = try await PhotoWallPageSelection.page(from: candidates, offset: offset, limit: Int.max, snapshot: snapshot)
            #expect(page.records.count <= 48)
            loaded += page.records.map(\.id)
            if page.records.isEmpty { emptyPages += 1 }
            guard let next = page.nextOffset else { didFinish = true; break }
            #expect(next > offset && next - offset <= 512)
            offset = next
        }
        #expect(didFinish && emptyPages >= 2)
        #expect(loaded == expected)
        #expect(Set(loaded).count == loaded.count)

        let firstCandidates = try await store.photoWallCandidates(in: snapshot.viewport, offset: 0)
        let firstPage = try await PhotoWallPageSelection.page(
            from: firstCandidates,
            offset: 0,
            limit: 48,
            snapshot: snapshot
        )
        let firstNextOffset = try #require(firstPage.nextOffset)
        let total = try await PhotoWallTotalSelection.count(
            startingAt: firstNextOffset,
            initialCount: firstPage.records.count,
            snapshot: snapshot
        ) { offset in
            try await store.photoWallCandidates(in: snapshot.viewport, offset: offset)
        }
        #expect(total == expected.count)
    }

    @Test(arguments: [
        GlobeCameraState(center: GeoCoordinate(latitude: 0, longitude: 179), distance: 800_000),
        GlobeCameraState(center: GeoCoordinate(latitude: 35, longitude: 139), distance: 10_000_000),
        GlobeCameraState(center: GeoCoordinate(latitude: 50, longitude: 2), distance: 10_000_000),
        GlobeCameraState(center: GeoCoordinate(latitude: 64, longitude: -22), distance: 10_000_000),
        GlobeCameraState(center: GeoCoordinate(latitude: -80, longitude: 179), distance: 42_000_000)
    ]) func nativeVisibleGroundIsNotLostBySpatialPrefilter(camera: GlobeCameraState) async throws {
        let map = makeMap()
        map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: camera.center.latitude, longitude: camera.center.longitude),
                                 fromDistance: camera.distance, pitch: camera.presentationPitch, heading: 0), animated: false)
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = try #require(MapViewportSampler.photoSnapshot(in: map))
        let bounds = PhotoSpatialBounds(viewport: snapshot.viewport)
        var visibleCount = 0
        for x in stride(from: 40.0, through: 1880, by: 115) {
            for y in stride(from: 30.0, through: 1050, by: 85) {
                let point = CGPoint(x: x, y: y)
                let ground = coordinate(point, map)
                guard ground.isValid else { continue }
                let projected = map.convert(CLLocationCoordinate2D(latitude: ground.latitude, longitude: ground.longitude), toPointTo: map)
                guard hypot(projected.x - x, projected.y - y) < 1 else { continue }
                visibleCount += 1
                #expect(snapshot.viewport.contains(ground))
                #expect(snapshot.containsCoordinate(ground))
                #expect(ground.latitude >= bounds.minimumLatitude && ground.latitude <= bounds.maximumLatitude)
                #expect(bounds.longitudeRanges.contains { $0.contains(ground.longitude) })
            }
        }
        #expect(visibleCount > 20)
    }

    @Test func invalidatedSelectionsCannotReturnPhotos() async throws {
        var current = true
        let viewport = EarthViewport(center: GeoCoordinate(latitude: 0, longitude: 0), angularRadius: 20)
        let candidates = PhotoQueryPage(records: [photo("one", viewport.center, time: 1)], nextOffset: nil)
        let snapshot = PhotoViewportSnapshot(viewport: viewport, isCurrent: { current }, containsCoordinate: { _ in
            current = false
            return true
        })
        await #expect(throws: PhotoWallSelectionError.self) {
            try await PhotoWallPageSelection.page(from: candidates, offset: 0, limit: 48, snapshot: snapshot)
        }
        let capture = PhotoWallViewportCapture()
        #expect(capture.freeze() == nil)
    }

    @Test func cancelledSpatialReadAndProjectionCannotPublishAPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        try await store.save(TravelClusterer().makeIndex(records: [photo("one", center, time: 1)]))
        let viewport = EarthViewport(center: center, angularRadius: 20)
        let cancelledRead = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.photoWallCandidates(in: viewport, offset: 0)
        }
        await #expect(throws: CancellationError.self) { try await cancelledRead.value }
        let snapshot = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in true })
        let candidates = try await store.photoWallCandidates(in: viewport, offset: 0)
        let cancelledProjection = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhotoWallPageSelection.page(from: candidates, offset: 0, limit: 48, snapshot: snapshot)
        }
        await #expect(throws: CancellationError.self) { try await cancelledProjection.value }
        #expect(try await PhotoWallPageSelection.page(from: candidates, offset: 0, limit: 48, snapshot: snapshot).records.count == 1)
    }

    private func makeMap() -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: 0)
        map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 20),
                                 fromDistance: GlobeCameraState.regionalDistance, pitch: 0, heading: 0), animated: false)
        map.layoutIfNeeded()
        return map
    }

    private func coordinate(_ point: CGPoint, _ map: MKMapView) -> GeoCoordinate {
        let value = map.convert(point, toCoordinateFrom: map)
        return GeoCoordinate(latitude: value.latitude, longitude: value.longitude)
    }

    private func photo(_ id: String, _ coordinate: GeoCoordinate, time: Double) -> PhotoAssetRecord {
        PhotoAssetRecord(id: id, coordinate: coordinate, creationDate: Date(timeIntervalSince1970: time),
                         pixelWidth: 1600, pixelHeight: 1000, isFavorite: false)
    }
}
