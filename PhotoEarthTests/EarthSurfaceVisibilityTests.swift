import Foundation
import Testing
@testable import PhotoEarth

struct EarthSurfaceVisibilityTests {
    @Test func tiltedOrbitUsesTheEyePositionToRejectTheFarSide() {
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let cap = EarthSurfaceVisibility(center: center, distance: 10_000_000, pitch: 35, heading: 0)
        let viewport = EarthViewport(center: center, angularRadius: 87.48, visibilityCap: cap)

        #expect(abs(cap.center.latitude + 21.4981) < 0.0001)
        #expect(abs(cap.center.longitude) < 0.0001)
        #expect(abs(cap.angularRadius - 65.9799) < 0.0001)
        #expect(viewport.contains(center))
        #expect(viewport.contains(GeoCoordinate(latitude: -80, longitude: 0)))
        #expect(!viewport.contains(GeoCoordinate(latitude: 60, longitude: 0)))
        // The old circle accepts this hidden point; fixtures without a camera
        // visibility cap retain their previous selection semantics.
        #expect(EarthViewport(center: center, angularRadius: 87.48)
            .contains(GeoCoordinate(latitude: 60, longitude: 0)))
    }

    @Test func changingHeadingChangesTheVisibleSideWithoutChangingTheLookAtCircle() {
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let north = EarthSurfaceVisibility(center: center, distance: 10_000_000, pitch: 35, heading: 0)
        let south = EarthSurfaceVisibility(center: center, distance: 10_000_000, pitch: 35, heading: 180)
        let previous = EarthViewport(center: center, angularRadius: 87.48, visibilityCap: north)
        let current = EarthViewport(center: center, angularRadius: 87.48, visibilityCap: south)

        #expect(current.contains(GeoCoordinate(latitude: 80, longitude: 0)))
        #expect(!current.contains(GeoCoordinate(latitude: -60, longitude: 0)))
        #expect(current.differsMeaningfully(from: previous))
        #expect(!current.differsMeaningfully(from: current))
        #expect(current.differsMeaningfully(from: EarthViewport(center: center, angularRadius: 87.48)))
    }

    @Test func bothCapsMustContainThePhoto() {
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let cap = EarthSurfaceVisibility(center: center, distance: 10_000_000, pitch: 35, heading: 0)
        let viewport = EarthViewport(center: center, angularRadius: 30, visibilityCap: cap)
        let outsideFrame = GeoCoordinate(latitude: -60, longitude: 0)
        #expect(cap.contains(outsideFrame))
        #expect(!viewport.contains(outsideFrame))
        #expect(viewport.contains(GeoCoordinate(latitude: -20, longitude: 0)))
    }

    @Test func tiltedVisibilityCrossesTheDateLineWithoutMirroringTheHeading() {
        let center = GeoCoordinate(latitude: 0, longitude: 179)
        let cap = EarthSurfaceVisibility(center: center, distance: 10_000_000, pitch: 35, heading: 90)
        let viewport = EarthViewport(center: center, angularRadius: 87.48, visibilityCap: cap)
        #expect(abs(cap.center.longitude - 157.5019) < 0.0001)
        #expect(viewport.contains(GeoCoordinate(latitude: 0, longitude: 110)))
        #expect(!viewport.contains(GeoCoordinate(latitude: 0, longitude: -121)))
    }

    @Test func overheadCityVisibilityPreservesTheSmallViewport() {
        let center = GeoCoordinate(latitude: 35.68, longitude: 139.76)
        let cap = EarthSurfaceVisibility(center: center, distance: 5_000, pitch: 0, heading: 0)
        let viewport = EarthViewport(center: center, angularRadius: 0.01, visibilityCap: cap)
        #expect(GlobeMath.angularDistanceDegrees(from: center, to: cap.center) < 0.000_001)
        #expect(viewport.contains(GeoCoordinate(latitude: 35.683, longitude: 139.76)))
        #expect(!viewport.contains(GeoCoordinate(latitude: 35.70, longitude: 139.76)))
    }

    @Test func representativesAndPagedPhotosExcludeHiddenNewerRecords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SQLiteTravelIndexStore(databaseURL: folder.appendingPathComponent("visibility.sqlite"))
        let center = GeoCoordinate(latitude: 0, longitude: 0)
        let cap = EarthSurfaceVisibility(center: center, distance: 10_000_000, pitch: 35, heading: 0)
        let viewport = EarthViewport(center: center, angularRadius: 87.48, visibilityCap: cap)
        // More than the 128-row page candidate batch are valid geographic
        // records in the primary circle, but hidden behind the pitched globe.
        let hidden = (0..<130).map { index in
            photo(id: "hidden-\(index)", latitude: 60, longitude: 0,
                  date: 3_000 + Double(index), favorite: true)
        }
        // Equal dates exercise the secondary stable id ordering across pages.
        let visible = (0..<5).map { index in
            photo(id: "visible-\(index)", latitude: 0, longitude: Double(index) * 0.01,
                  date: 2_000, favorite: false)
        }
        let records = hidden + visible
        try await store.save(TravelClusterer().makeIndex(records: records))

        let representatives = try await store.photos(in: viewport, limit: 18)
        #expect(!representatives.isEmpty)
        #expect(representatives.count <= 18)
        #expect(representatives.allSatisfy { $0.id.hasPrefix("visible-") })
        let fixturePhotos = PhotoSpatialIndex(records: records).photos(in: viewport, limit: 18)
        #expect(Set(fixturePhotos.map(\.id)) == Set(visible.map(\.id)))

        var offset = 0
        var pagedIDs: [String] = []
        for pageNumber in 0..<3 {
            let page = try await store.photoPage(in: viewport, offset: offset, limit: 2)
            #expect(page.records.count <= 2)
            pagedIDs.append(contentsOf: page.records.map(\.id))
            if pageNumber < 2 {
                offset = try #require(page.nextOffset)
                #expect(offset > 128)
            } else {
                #expect(page.nextOffset == nil)
            }
        }
        #expect(pagedIDs == visible.map(\.id))
        #expect(Set(pagedIDs).count == pagedIDs.count)
    }

    private func photo(
        id: String, latitude: Double, longitude: Double, date: Double, favorite: Bool
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: id, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            creationDate: Date(timeIntervalSince1970: date),
            pixelWidth: 4_000, pixelHeight: 3_000, isFavorite: favorite
        )
    }
}
