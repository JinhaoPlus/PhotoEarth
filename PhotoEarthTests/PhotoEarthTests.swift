//
//  PhotoEarthTests.swift
//  PhotoEarthTests
//
//  Created by doupi on 2026/9/4.
//

import Foundation
import Testing
@testable import PhotoEarth

struct PhotoEarthTests {
    @Test func localPreferencesRoundTripWithoutICloudEntitlement() async throws {
        let suiteName = "PhotoEarthTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalPreferenceStore(defaults: defaults)
        var expected = SyncedPreferences()
        expected.onboardingCompleted = true
        expected.autoplayEnabled = false
        expected.lastSelectedPlaceID = "place-reykjavik"

        await store.save(expected)
        let actual = await store.load()

        #expect(actual == expected)
    }

    @Test func globeCoordinatesUseExpectedAxes() {
        let equator = GlobeMath.cartesian(
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            radius: 1
        )
        let northPole = GlobeMath.cartesian(
            coordinate: GeoCoordinate(latitude: 90, longitude: 0),
            radius: 1
        )

        #expect(abs(equator.x) < 0.0001)
        #expect(abs(equator.y) < 0.0001)
        #expect(abs(equator.z - 1) < 0.0001)
        #expect(abs(northPole.y - 1) < 0.0001)
    }

    @Test func nearbyPhotosBecomeOnePlaceAndDistantPhotosSplit() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record("a", latitude: 31.2304, longitude: 121.4737, date: start),
            record("b", latitude: 31.2310, longitude: 121.4800, date: start.addingTimeInterval(3_600)),
            record("c", latitude: 35.6762, longitude: 139.6503, date: start.addingTimeInterval(86_400)),
        ]

        let snapshot = TravelClusterer().makeIndex(records: records)
        let index = snapshot.index

        #expect(index.places.count == 2)
        #expect(index.places[0].photoCount == 2)
        #expect(index.places[1].photoCount == 1)
        #expect(index.locatedPhotoCount == 3)
        #expect(snapshot.photos.map(\.id) == ["a", "b", "c"])
        #expect(snapshot.photos.allSatisfy { $0.placeID != nil })
        #expect(Set(snapshot.photos.prefix(2).compactMap(\.placeID)).count == 1)
    }

    @Test func globeCameraWrapsLongitudeAndClampsLatitudeAndDistance() {
        var camera = GlobeCameraState(
            center: GeoCoordinate(latitude: 82, longitude: 178),
            distance: GlobeCameraState.defaultDistance
        )

        camera.rotate(longitudeDelta: 8, latitudeDelta: 12)
        #expect(camera.center.longitude == -174)
        #expect(camera.center.latitude == 84)

        camera.zoom(logarithmicDelta: -100)
        #expect(camera.distance == GlobeCameraState.minimumDistance)
        camera.zoom(logarithmicDelta: 100)
        #expect(camera.distance == GlobeCameraState.maximumDistance)
    }

    @Test func ringRecognizerUnwrapsAnglesAndIgnoresCenterTouches() {
        var recognizer = RingRotationRecognizer()

        #expect(recognizer.update(x: 0.1, y: 0.1, isTouching: true) == nil)
        #expect(recognizer.update(
            x: cos(179 * .pi / 180),
            y: sin(179 * .pi / 180),
            isTouching: true
        ) == nil)
        #expect(recognizer.update(
            x: cos(-176 * .pi / 180),
            y: sin(-176 * .pi / 180),
            isTouching: true
        )! > 0)

        recognizer.reset()
        _ = recognizer.update(
            x: cos(90 * .pi / 180),
            y: sin(90 * .pi / 180),
            isTouching: true
        )
        let clockwise = recognizer.update(
            x: cos(72 * .pi / 180),
            y: sin(72 * .pi / 180),
            isTouching: true
        )
        #expect(clockwise != nil)
        #expect(clockwise! < 0)
    }

    @Test func spatialIndexSelectsFrontFacingPhotosAcrossDateLine() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record("east", latitude: 10, longitude: 179, date: date),
            record("west", latitude: 10, longitude: -179, date: date),
            record("opposite", latitude: 10, longitude: 0, date: date),
        ]
        let index = PhotoSpatialIndex(records: records)

        let result = index.photos(
            in: EarthViewport(
                center: GeoCoordinate(latitude: 10, longitude: 180),
                angularRadius: 6
            )
        )

        #expect(Set(result.map(\.id)) == Set(["east", "west"]))
    }

    @Test func bundledFixtureCoordinatesResolveWithoutNetwork() throws {
        let sydney = try #require(BundledPlaceFallbackCatalog.label(
            near: GeoCoordinate(latitude: -33.86632, longitude: 151.21156)
        ))

        #expect(sydney.city == "悉尼")
        #expect(sydney.country == "澳大利亚")
        #expect(BundledPlaceFallbackCatalog.label(
            near: GeoCoordinate(latitude: 20, longitude: 20)
        ) == nil)
    }

    @Test func indexRoundTripsThroughDisk() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-earth-tests-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = SQLiteTravelIndexStore(databaseURL: file)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = TravelClusterer().makeIndex(
            records: [
                record("asset-1", latitude: 64.1466, longitude: -21.9426, date: date),
                record("asset-2", latitude: 64.15, longitude: -21.94, date: date.addingTimeInterval(60)),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try await store.save(expected)
        let actual = try await store.load()
        let visible = try await store.photos(
            in: EarthViewport(
                center: GeoCoordinate(latitude: 64.1466, longitude: -21.9426),
                angularRadius: 4
            ),
            limit: 18
        )
        let page = try await store.assetIDs(
            for: expected.index.places[0].id,
            offset: 1,
            limit: 1
        )
        let viewport = EarthViewport(
            center: GeoCoordinate(latitude: 64.1466, longitude: -21.9426),
            angularRadius: 4
        )
        let firstWallPage = try await store.photoPage(in: viewport, offset: 0, limit: 1)
        let secondWallPage = try await store.photoPage(
            in: viewport,
            offset: try #require(firstWallPage.nextOffset),
            limit: 1
        )
        let latestAssetID = try await store.latestAssetID(for: expected.index.places[0].id)
        var renamedPlace = expected.index.places[0]
        renamedPlace.name = "雷克雅未克"
        renamedPlace.country = "冰岛"
        try await store.updatePlaceNames([renamedPlace])
        let updatedIndex = try #require(try await store.load())

        #expect(actual == expected.index)
        #expect(Set(visible.map(\.id)) == Set(["asset-1", "asset-2"]))
        #expect(page == ["asset-2"])
        #expect(firstWallPage.records.map(\.id) == ["asset-2"])
        #expect(secondWallPage.records.map(\.id) == ["asset-1"])
        #expect(secondWallPage.nextOffset != firstWallPage.nextOffset)
        #expect(latestAssetID == "asset-2")
        #expect(updatedIndex.places[0].name == "雷克雅未克")
        #expect(updatedIndex.places[0].country == "冰岛")
    }

    @Test func corruptedSQLiteIndexIsDiscardedForRebuild() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-earth-corrupt-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: file)

        let store = SQLiteTravelIndexStore(databaseURL: file)
        let loaded = try await store.load()

        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func sqliteIndexScalesToFiftyThousandPhotos() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-earth-scale-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("index.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }

        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let placeCount = 50
        let photosPerPlace = 1_000
        let places = (0..<placeCount).map { placeOffset in
            let coordinate = GeoCoordinate(
                latitude: -70 + Double(placeOffset % 15) * 10,
                longitude: -175 + Double(placeOffset % 36) * 10
            )
            return TravelPlace(
                id: "scale-place-\(placeOffset)",
                name: "Scale Place \(placeOffset)",
                country: nil,
                coordinate: coordinate,
                startDate: start.addingTimeInterval(Double(placeOffset) * 86_400),
                endDate: start.addingTimeInterval(Double(placeOffset + 1) * 86_400),
                photoCount: photosPerPlace,
                coverAssetID: "scale-\(placeOffset)-0"
            )
        }
        var photos: [PhotoAssetRecord] = []
        photos.reserveCapacity(placeCount * photosPerPlace)
        for (placeOffset, place) in places.enumerated() {
            for photoOffset in 0..<photosPerPlace {
                let latitudeOffset = Double(photoOffset % 9 - 4) * 0.02
                let longitudeOffset = Double(photoOffset % 11 - 5) * 0.02
                photos.append(PhotoAssetRecord(
                    id: "scale-\(placeOffset)-\(photoOffset)",
                    coordinate: GeoCoordinate(
                        latitude: place.coordinate.latitude + latitudeOffset,
                        longitude: place.coordinate.longitude + longitudeOffset
                    ),
                    creationDate: place.startDate.addingTimeInterval(Double(photoOffset) * 60),
                    pixelWidth: 4_000,
                    pixelHeight: photoOffset.isMultiple(of: 3) ? 4_000 : 3_000,
                    isFavorite: photoOffset.isMultiple(of: 97),
                    placeID: place.id
                ))
            }
        }
        let index = TravelIndex(
            schemaVersion: TravelIndex.currentSchemaVersion,
            generatedAt: start,
            sourcePhotoCount: photos.count,
            locatedPhotoCount: photos.count,
            places: places,
            journeys: [TravelJourney(
                id: "scale-journey",
                title: "Scale Journey",
                startDate: places[0].startDate,
                endDate: places[placeCount - 1].endDate,
                placeIDs: places.map(\.id)
            )]
        )
        let store = SQLiteTravelIndexStore(databaseURL: file)

        let saveStartedAt = Date()
        try await store.save(TravelIndexSnapshot(index: index, photos: photos))
        let saveDuration = Date().timeIntervalSince(saveStartedAt)
        let loaded = try await store.load()
        let queryStartedAt = Date()
        let visible = try await store.photos(
            in: EarthViewport(
                center: GeoCoordinate(latitude: 0, longitude: 0),
                angularRadius: 94
            ),
            limit: 18
        )
        let queryDuration = Date().timeIntervalSince(queryStartedAt)
        let finalPage = try await store.assetIDs(
            for: "scale-place-12",
            offset: 995,
            limit: 20
        )
        let fileSize = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        ).intValue
        print(String(
            format: "PHOTO_EARTH_SCALE rows=50000 bytes=%d save=%.3fs query=%.3fs",
            fileSize,
            saveDuration,
            queryDuration
        ))

        #expect(loaded?.locatedPhotoCount == 50_000)
        #expect(loaded?.places.count == placeCount)
        #expect(loaded?.places.reduce(0) { $0 + $1.photoCount } == 50_000)
        #expect(visible.count == 18)
        #expect(visible.allSatisfy {
            GlobeMath.angularDistanceDegrees(
                from: GeoCoordinate(latitude: 0, longitude: 0),
                to: $0.coordinate
            ) <= 94
        })
        #expect(finalPage.count == 5)
        #expect(fileSize < 50 * 1_024 * 1_024)
    }

    @Test func clusteringFiftyThousandPhotosUsesRunningCentroid() {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let records = (0..<50_000).map { offset in
            PhotoAssetRecord(
                id: "dense-\(offset)",
                coordinate: GeoCoordinate(
                    latitude: 31.23 + Double(offset % 7) * 0.0001,
                    longitude: 121.47 + Double(offset % 11) * 0.0001
                ),
                creationDate: start.addingTimeInterval(Double(offset) * 60),
                pixelWidth: 4_000,
                pixelHeight: 3_000,
                isFavorite: false
            )
        }

        let snapshot = TravelClusterer().makeIndex(records: records, generatedAt: start)

        #expect(snapshot.index.locatedPhotoCount == 50_000)
        #expect(snapshot.index.places.count == 1)
        #expect(snapshot.index.places[0].photoCount == 50_000)
        #expect(snapshot.photos.allSatisfy { $0.placeID == snapshot.index.places[0].id })
    }

    @Test func innerTouchSurfaceGrabsGlobeInFingerDirection() {
        var camera = GlobeCameraState(
            center: GeoCoordinate(latitude: 0, longitude: 0),
            distance: GlobeCameraState.defaultDistance
        )

        camera.panWithTouchSurface(
            horizontalDelta: 0.2,
            verticalDelta: 0.1,
            sensitivity: 50
        )

        #expect(camera.center.longitude == -10)
        #expect(abs(camera.center.latitude + 3.8) < 0.0001)
    }

    @Test func remoteSurfaceSeparatesInnerPanFromOuterRing() throws {
        var recognizer = RemoteSurfaceGestureRecognizer()
        #expect(recognizer.update(x: 0.1, y: 0.1, isTouching: true) == nil)
        let panResult = recognizer.update(x: 0.25, y: 0.16, isTouching: true)
        let pan = try #require(panResult)
        guard case let .pan(horizontalDelta, verticalDelta) = pan else {
            Issue.record("Inner touch should produce a pan gesture")
            return
        }
        #expect(horizontalDelta > 0)
        #expect(verticalDelta > 0)

        recognizer.reset()
        #expect(recognizer.update(x: 0, y: 0.9, isTouching: true) == nil)
        let ringResult = recognizer.update(
            x: cos(72 * .pi / 180) * 0.9,
            y: sin(72 * .pi / 180) * 0.9,
            isTouching: true
        )
        let ring = try #require(ringResult)
        guard case let .ring(angleDelta) = ring else {
            Issue.record("Outer touch should produce a ring gesture")
            return
        }
        #expect(angleDelta < 0)
    }

    @Test func mapPlaceLODHardLimitsDenseLocations() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var places: [TravelPlace] = []
        for offset in 0..<250 {
            let timestamp = start.addingTimeInterval(Double(offset) * 60)
            places.append(TravelPlace(
                id: "dense-place-\(offset)",
                name: "Dense Place \(offset)",
                country: nil,
                coordinate: GeoCoordinate(
                    latitude: 31.2304 + Double(offset % 5) * 0.001,
                    longitude: 121.4737 + Double(offset % 7) * 0.001
                ),
                startDate: timestamp,
                endDate: timestamp,
                photoCount: 1,
                coverAssetID: nil
            ))
        }

        let visible = MapPlaceLOD.representatives(from: places, limit: 180)

        #expect(visible.count == 2)
        #expect(Set(visible.map { $0.id }) == Set(["dense-place-248", "dense-place-249"]))
    }

    private func record(
        _ id: String,
        latitude: Double,
        longitude: Double,
        date: Date
    ) -> PhotoAssetRecord {
        PhotoAssetRecord(
            id: id,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            creationDate: date,
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            isFavorite: false
        )
    }
}
