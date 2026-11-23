import Foundation
import Testing
import MapKit
import SwiftUI
@testable import PhotoEarth

struct MapReviewTests {
    @Test func collectionOriginUsesPinnedMembersInsteadOfTheLatestGlobalPlace() throws {
        let fixture = SampleTravelIndex.make().index.places
        let members = Array(fixture.suffix(2))
        let ids = members.map(\.id)
        let origin = try #require(MapReviewOrigin.collection(placeIDs: ids + ids, in: fixture))
        #expect(origin.placeIDs == ids.sorted())
        #expect(origin.reference == members[0].coordinate)
        #expect(MapReviewOrigin.collection(placeIDs: [], in: fixture) == nil)
        #expect(MapReviewOrigin.collection(placeIDs: ["missing"], in: fixture) == nil)
    }

    @Test func multiPlaceOpeningExtentUsesAllPinnedMembersAndKeepsItsReadVersion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-review-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = [photo(0, latitude: 0.01, longitude: 179.99, placeID: "first"),
                      photo(1, latitude: 0.02, longitude: -179.99, placeID: "second"),
                      photo(2, latitude: -10, longitude: 120, placeID: "unrelated")]
        let places = photos.map { record in
            TravelPlace(id: record.placeID!, name: "Fixture", country: "Fixture Country", coordinate: record.coordinate,
                        startDate: record.creationDate, endDate: record.creationDate, photoCount: 1, coverAssetID: record.id)
        }
        try await store.save(TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
            generatedAt: Date(), sourcePhotoCount: 3, locatedPhotoCount: 3, places: places, journeys: []), photos: photos))
        let reader = try await store.photoReadSnapshot()
        let ids = ["first", "second", "first"] + (0..<1_200).map { "absent-\($0)" }
        let grid = MapReviewGrid.world(around: 180)
        let cluster = try #require(try await reader.mapReviewClusters(placeIDs: ids, grid: grid).first)
        #expect(cluster.count == 2)
        #expect(cluster.coordinate == photos[0].coordinate)
        #expect(cluster.assetID == photos[0].id)
        #expect(cluster.south == 0.01 && cluster.north == 0.02)
        #expect(cluster.east - cluster.west < 0.03)
        let excludingCover = try #require(try await reader.mapReviewClusters(placeIDs: ids, grid: grid, excluding: [photos[0].id]).first)
        #expect(excludingCover.count == 1 && excludingCover.coordinate == photos[1].coordinate)
        #expect(try await reader.mapReviewClusters(placeIDs: [], grid: grid).isEmpty)
        try await store.save(snapshot([photo(10, latitude: 10, longitude: 10)]))
        #expect(try await reader.mapReviewClusters(placeIDs: ids, grid: grid).first?.count == 2)
        #expect(try await store.mapReviewClusters(placeIDs: ids, grid: grid).isEmpty)
    }

    @Test func cityLandingFitsDistinctPositionsAcrossDateLineAndIgnoresIsolatedOutlier() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("city-frame-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let walk = (0..<64).map { i in
            photo(i, latitude: 41 + Double(i) / 10_000,
                  longitude: MapReviewGrid.normalizedLongitude(179.998 + Double(i) / 10_000))
        }
        let repeats = (64..<400).map { photo($0, latitude: 41, longitude: 179.998) }
        let distant = photo(401, latitude: 45, longitude: 150)
        let photos = walk + repeats + [distant]
        try await store.save(snapshot(photos))
        let actual = try #require(try await store.cityLandingFrame(placeIDs: ["visit"], reference: 180, excluding: []))
        let expected = try #require(CityLandingFrame.demo(coordinates: Set(photos.map(\.coordinate)), reference: 180))
        #expect(actual.camera == expected.camera)
        #expect(abs(actual.camera.center.longitude) > 179.9)
        #expect((1_500...3_000).contains(actual.camera.distance))
        let single = try #require(try await store.cityLandingFrame(placeIDs: ["visit"], reference: 180,
                                                                   excluding: Set(walk.dropFirst().map(\.id) + [distant.id])))
        #expect(single.camera.distance == 1_500)
        #expect(try await store.cityLandingFrame(placeIDs: ["elsewhere"], reference: 180, excluding: []) == nil)
    }

    @Test @MainActor func viewportReviewCanMoveAndZoomWithoutChangingTheSourceWallProjection() async throws {
        let source = MKMapView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        source.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        source.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 48.86, longitude: 2.3),
                                    fromDistance: 800_000, pitch: 0, heading: 0), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let capture = PhotoWallViewportCapture()
        capture.attach(source)
        let frozen = try #require(capture.freeze())
        let original = source.camera.copy() as! MKMapCamera
        let review = MapReviewCamera()
        defer { review.stop() }
        review.map.frame = source.frame
        review.show(center: frozen.camera.center, distance: frozen.camera.distance)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(review.map.centerCoordinate.latitude - original.centerCoordinate.latitude) < 0.0001)
        #expect(abs(review.map.centerCoordinate.longitude - original.centerCoordinate.longitude) < 0.0001)
        #expect(abs(review.map.camera.centerCoordinateDistance - original.centerCoordinateDistance) < 100)
        review.nudge(.right)
        review.zoom(inward: true, animated: false)
        review.toggleStyle()
        #expect(frozen.snapshot.isCurrent())
        #expect(source.camera.centerCoordinate.latitude == original.centerCoordinate.latitude)
        #expect(source.camera.centerCoordinate.longitude == original.centerCoordinate.longitude)
        #expect(source.camera.centerCoordinateDistance == original.centerCoordinateDistance)
        #expect(frozen.snapshot.containsCoordinate(frozen.camera.center))
    }

    @Test @MainActor func aChainOfNearbyShootingLocationsKeepsDistinctVisibleAnchors() throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.show(center: .init(latitude: 41, longitude: 2), distance: 14_000)
        let clusters = (0..<6).map { i in
            let native = camera.map.convert(CGPoint(x: 500 + i * 80, y: 500), toCoordinateFrom: camera.map)
            let coordinate = GeoCoordinate(latitude: native.latitude, longitude: native.longitude)
            return MapReviewCluster(cell: .init(column: i, row: 0), count: 6 - i, coordinate: coordinate,
                                    south: native.latitude, north: native.latitude, west: native.longitude,
                                    east: native.longitude, assetID: "cover-\(i)")
        }
        let pins = camera.pins(clusters.reversed())
        #expect(pins.count == 3)
        #expect(pins.map(\.count).reduce(0, +) == 21)
        #expect(pins.map { $0.clusters[0].cell.column } == [0, 2, 4])
    }

    @Test @MainActor func coastalAggregationUsesTheCoverGPSInsteadOfAMidpoint() async throws {
        let photos = [photo(0, latitude: 37.7749, longitude: -122.4194),
                      photo(1, latitude: 37.8044, longitude: -122.2711)]
        let grid = MapReviewGrid.world(around: -122.4)
        var accumulator = MapReviewClusterAccumulator(grid: grid)
        photos.forEach { accumulator.insert($0) }
        let cluster = try #require(accumulator.clusters.values.first)
        #expect(cluster.count == 2)
        #expect(cluster.coordinate == photos[0].coordinate)
        #expect(cluster.assetID == photos[0].id)
        #expect(cluster.east > cluster.west, "The aggregate keeps all member bounds independently of its real photo anchor")
        let demo = MapReviewCluster.demo(records: Array(photos.reversed()), grid: grid)
        #expect(demo.first?.coordinate == photos[0].coordinate)

        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: photos[0].coordinate.latitude, longitude: photos[0].coordinate.longitude),
                                       fromDistance: 1_000_000, pitch: 0, heading: 0), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let members = photos.enumerated().map { index, photo in
            MapReviewCluster(cell: MapReviewCell(column: index, row: 0), count: 1, coordinate: photo.coordinate,
                south: photo.coordinate.latitude, north: photo.coordinate.latitude,
                west: photo.coordinate.longitude, east: photo.coordinate.longitude, assetID: photo.id)
        }
        let anchor = try #require(camera.pinAnchors(members).first)
        let cover = try #require(photos.first { $0.id == anchor.clusters.first?.assetID })
        #expect(anchor.coordinate == cover.coordinate, "Native merging must also keep a real photo GPS")
    }

    @Test(arguments: [GeoCoordinate(latitude: 48.85837, longitude: 2.29448),
                      GeoCoordinate(latitude: 31.24, longitude: 121.5),
                      GeoCoordinate(latitude: -33.86, longitude: 151.2),
                      GeoCoordinate(latitude: 0, longitude: -179.999),
                      GeoCoordinate(latitude: 83, longitude: 20)])
    @MainActor func nativePinsStayRegisteredWithTheMapDespiteContainerOffsetsAndStyleChanges(coordinate: GeoCoordinate) async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        camera.map.frame = CGRect(x: -40, y: -60, width: 1920, height: 1200)
        controller.view.addSubview(camera.map)
        let cluster = MapReviewCluster(cell: MapReviewCell(column: 0, row: 0), count: 120, coordinate: coordinate,
            south: coordinate.latitude, north: coordinate.latitude, west: coordinate.longitude,
            east: coordinate.longitude, assetID: "sample-paris-1")
        camera.fit(cluster, animated: false)
        let anchor = MapReviewPinAnchor(clusters: [cluster], coordinate: coordinate)
        camera.displayPins([anchor], isActive: true)
        for step in 0..<4 {
            if step == 1 { camera.nudge(.right) }
            if step == 2 { camera.toggleStyle() }
            if step == 3 { camera.zoom(inward: true, animated: false) }
            let annotation = try #require(camera.map.annotations.first as? MapReviewPhotoAnnotation)
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            var offset = Double.infinity
            var alignedFrames = 0
            while ContinuousClock.now < deadline, alignedFrames < 3 {
                try await Task.sleep(for: .milliseconds(32))
                camera.map.layoutIfNeeded()
                guard let view = camera.map.view(for: annotation) as? MapReviewPhotoAnnotationView else {
                    alignedFrames = 0
                    continue
                }
                let actual = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: camera.map)
                let expected = camera.map.convert(annotation.coordinate, toPointTo: camera.map)
                offset = hypot(actual.x - expected.x, actual.y - expected.y)
                alignedFrames = offset < 2 ? alignedFrames + 1 : 0
            }
            let view = try #require(camera.map.view(for: annotation) as? MapReviewPhotoAnnotationView)
            #expect(alignedFrames == 3, "Native marker did not settle at its GPS after operation \(step), last offset \(offset) pt")
            #expect(annotation.coordinate.latitude == coordinate.latitude)
            #expect(annotation.coordinate.longitude == coordinate.longitude)
            #expect(!view.canBecomeFocused)
            #expect(!view.isUserInteractionEnabled)
            #expect(camera.map.annotations.count == 1)
        }
        let annotation = try #require(camera.map.annotations.first)
        camera.displayPins([anchor], isActive: true)
        #expect(camera.map.annotations.first === annotation, "Identical renders cannot recreate pins or their photo loaders")
        camera.displayPins([], isActive: true)
        #expect(camera.map.annotations.isEmpty)
    }

    @Test @MainActor func nearGlobePinCountsMatchTheFrozenWallAndRespectFixedCityMembership() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scale-members-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = (0..<1_300).map { i in
            photo(i, latitude: 31 + Double(i % 4) / 100, longitude: 121 + Double(i % 7) / 100)
        }
        try await store.save(snapshot(photos))
        let app = AppModel()
        let reader = try await store.photoReadSnapshot()
        let viewport = EarthViewport(center: photos[0].coordinate, angularRadius: 1)
        let projected = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true },
                                              containsCoordinate: { $0.longitude <= 121.04 })
        let grid = MapReviewGrid(viewport: viewport, size: CGSize(width: 1920, height: 1080))
        var previews: [[PhotoAssetRecord]] = []
        let pins = try await app.viewportPhotoBatch(in: projected, grid: grid, reader: reader, placeIDs: ["visit"],
                                                   onPreview: { previews.append($0) }, isCurrent: { true })
        #expect(previews == [pins.preview])
        #expect(previews.first?.allSatisfy { projected.containsCoordinate($0.coordinate) } == true)
        let wall = try await app.photoCount(in: projected, startingAt: 0, initialCount: 0, reader: reader)
        #expect(pins.count == wall)
        #expect(wall == photos.filter { projected.containsCoordinate($0.coordinate) }.count)
        #expect(pins.preview.count == 48)
        #expect(pins.clusters.allSatisfy { cluster in
            photos.first { $0.id == cluster.assetID }?.coordinate == cluster.coordinate
        })
        let outsideScope = try await reader.photoWallCountingCandidates(in: viewport, offset: 0,
                                                                       operationID: UUID(), placeIDs: ["elsewhere"])
        #expect(outsideScope.records.isEmpty && outsideScope.nextOffset == nil)
        let anotherCity = try await app.viewportPhotoBatch(in: projected, grid: grid, reader: reader,
                                                          placeIDs: ["elsewhere"], isCurrent: { true })
        #expect(anotherCity.count == 0)
        #expect(anotherCity.preview.isEmpty)
    }

    @Test func oldQueryCleanupCannotCloseTheNewViewportCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-review-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = (0..<1_100).map { photo($0, latitude: 31.24, longitude: 121.5) }
        try await store.save(snapshot(photos))
        let reader = try await store.photoReadSnapshot()
        let viewport = EarthViewport(center: photos[0].coordinate, angularRadius: 10)
        let old = UUID(), current = UUID()
        _ = try await reader.photoWallCountingCandidates(in: viewport, offset: 0, operationID: old)
        let first = try await reader.photoWallCountingCandidates(in: viewport, offset: 0, operationID: current)
        await reader.finishPhotoWallCounting(operationID: old)
        await reader.finishPhotoWallCounting()
        let cancelledOldCall = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.photoWallCountingCandidates(in: viewport, offset: 512, operationID: old)
        }
        _ = try? await cancelledOldCall.value
        #expect(await reader.activePhotoCountOperationID == current)
        let second = try await reader.photoWallCountingCandidates(in: viewport, offset: 512, operationID: current)
        #expect(first.records + second.records == Array(photos.prefix(1024)))
        await reader.finishPhotoWallCounting(operationID: current)
        #expect(await reader.activePhotoCountOperationID == nil)
    }

    @Test @MainActor func dispersedFiftyThousandPhotosKeepBoundedGroupsAndRecordAggregationCost() async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                       fromDistance: 10_000_000, pitch: 0, heading: 0), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let grid = MapReviewGrid(south: -30, north: 30, west: -60, east: 60, referenceLongitude: 0, columns: 20, rows: 12)
        let photos = (0..<50_000).map { index in
            photo(index, latitude: -27.5 + Double((index / 20) % 12) * 5,
                  longitude: -57 + Double(index % 20) * 6)
        }
        var accumulator = MapReviewClusterAccumulator(grid: grid)
        let begin = ContinuousClock.now
        for photo in photos { accumulator.insert(photo) }
        let accumulation = begin.duration(to: .now)
        #expect(accumulator.clusters.count == 240)
        #expect(accumulator.clusters.values.reduce(0) { $0 + $1.count } == 50_000)
        let clusters = accumulator.clusters.values.filter { camera.point($0.coordinate) != nil }.sorted { $0.cell < $1.cell }
        let groupingBegin = ContinuousClock.now
        let anchors = camera.pinAnchors(clusters)
        let grouping = groupingBegin.duration(to: .now)
        #expect(anchors.count <= 32)
        let groupedTotal = anchors.flatMap(\.clusters).reduce(0) { $0 + $1.count }
        let visibleTotal = clusters.reduce(0) { $0 + $1.count }
        #expect(groupedTotal == visibleTotal)
        #expect(anchors.allSatisfy { $0.clusters.first?.coordinate == $0.coordinate })
        print("MapReview benchmark: records=50000 cells=240 visibleCells=\(clusters.count) pins=\(anchors.count) accumulate=\(accumulation) group=\(grouping)")
    }

    @Test @MainActor func movingPinsKeepTheirPhotosAndCountsButInvalidateTheViewportTotal() async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let coordinate = GeoCoordinate(latitude: 48.85837, longitude: 2.29448)
        let cluster = MapReviewCluster(cell: MapReviewCell(column: 0, row: 0), count: 120, coordinate: coordinate,
            south: coordinate.latitude, north: coordinate.latitude, west: coordinate.longitude,
            east: coordinate.longitude, assetID: "retained-cover")
        camera.fit(cluster, animated: false)
        try await waitForSettled(camera)
        let session = MapReviewSession()
        session.preparePins(excluding: [])
        session.acceptClusters([cluster], camera: camera)
        let initial = try #require(camera.projectedPins(session.pinAnchors).first)
        #expect(session.total == 120)

        // Pending movement and query cancellation must preserve the visual
        // grouping, without claiming its old total belongs to the new viewport.
        camera.pan(dx: 0.02, dy: 0)
        session.invalidate()
        #expect(camera.grid == nil)
        #expect(session.total == nil)
        #expect(!session.ready)
        #expect(camera.projectedPins(session.pinAnchors).first?.id == initial.id)
        camera.nudge(.right)
        try await Task.sleep(for: .milliseconds(100))
        let moved = try #require(camera.projectedPins(session.pinAnchors).first)
        #expect(camera.grid == nil)
        #expect(moved.id == initial.id)
        #expect(moved.assetID == "retained-cover")
        #expect(moved.count == 120)
        #expect(moved.point.x < initial.point.x - 1, "A fixed photo must follow the geographic surface, not its old screen position")

        camera.center(on: GeoCoordinate(latitude: 35.68, longitude: 139.76), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(camera.projectedPins(session.pinAnchors).isEmpty, "Old anchors outside the screen must be culled")
        #expect(session.pinAnchors.count == 1)
        session.acceptClusters([], camera: camera)
        #expect(session.pinAnchors.isEmpty, "A completed empty viewport must replace the retained pins")
        #expect(session.total == 0)
        #expect(session.ready)
    }

#if DEBUG
    @Test @MainActor func retryingTheViewportCountKeepsLoadedPagesAndTheirCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-review-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let coordinate = GeoCoordinate(latitude: 48.86, longitude: 2.29)
        let photos = (0..<97).map { photo($0, latitude: coordinate.latitude, longitude: coordinate.longitude) }
        try await store.save(snapshot(photos))
        let app = AppModel(photoLibrary: PreparationFixtureLibrary(records: photos), indexStore: store,
                           preferencesStore: LocalPreferenceStore(), clusterer: TravelClusterer())
        let camera = MapReviewCamera()
        defer { camera.stop() }
        let viewport = EarthViewport(center: coordinate, angularRadius: 1)
        let projection = PhotoViewportSnapshot(viewport: viewport, isCurrent: { true }, containsCoordinate: { _ in true })
        let grid = MapReviewGrid(viewport: viewport, size: CGSize(width: 1920, height: 1080))
        let session = MapReviewSession()

        // Exhaust the snapshot leases so the count fails while ordinary paging succeeds.
        let spareReader = try await store.photoReadSnapshot()
        var blockedLease: SQLiteTravelIndexStore? = try await store.photoReadSnapshot()
        await session.refresh(app: app, snapshot: projection, grid: grid, reader: nil, camera: camera)
        #expect(blockedLease != nil)
        try await waitForPage(session)
        #expect(session.records == Array(photos.prefix(48)))
        #expect(session.countFailed)
        #expect(session.pageError == nil)
        #expect(session.total == nil)

        let offset = try #require(session.nextOffset)
        session.page(app: app, reader: nil, at: offset, append: true)
        try await waitForPage(session)
        #expect(session.records == Array(photos.prefix(96)))
        #expect(session.countFailed)
        let nextOffset = try #require(session.nextOffset)

        blockedLease = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while session.countFailed {
            try #require(ContinuousClock.now < deadline, "Retry must recover after a read lease is released")
            let retry = try #require(session.retryCount(app: app, grid: grid, reader: nil, camera: camera))
            await retry.value
            if session.countFailed { try await Task.sleep(for: .milliseconds(20)) }
        }
        withExtendedLifetime(spareReader) {}
        #expect(session.total == photos.count)
        #expect(session.records == Array(photos.prefix(96)))
        #expect(session.nextOffset == nextOffset)
        #expect(session.pageError == nil)
    }
#endif

    @Test @MainActor func changingExcludedPhotosClearsRetainedPins() {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let coordinate = GeoCoordinate(latitude: 48.85837, longitude: 2.29448)
        let cluster = MapReviewCluster(cell: MapReviewCell(column: 0, row: 0), count: 1, coordinate: coordinate,
            south: coordinate.latitude, north: coordinate.latitude, west: coordinate.longitude,
            east: coordinate.longitude, assetID: "excluded-cover")
        camera.fit(cluster, animated: false)
        let session = MapReviewSession()
        session.preparePins(excluding: [])
        session.acceptClusters([cluster], camera: camera)
        #expect(session.pinAnchors.count == 1)
        session.invalidate()
        session.preparePins(excluding: ["excluded-cover"])
        #expect(session.pinAnchors.isEmpty)
        #expect(session.total == nil)
    }

    @Test @MainActor func releasingTouchBeforeTheDisplayFrameStillRestoresPins() async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.center(on: GeoCoordinate(latitude: 48.85837, longitude: 2.29448), animated: false)
        try await waitForSettled(camera)
        #expect(camera.grid != nil)
        let stoppedCamera = camera.map.camera.copy() as! MKMapCamera
        camera.touchContact(true)
        camera.pan(dx: 0.02, dy: 0)
        camera.touchContact(false)
        try await waitForSettled(camera)
        #expect(camera.grid != nil, "A final drag sample released before the next frame cannot strand the viewport")
        #expect(camera.snapshot?.isCurrent() == true)
        #expect(camera.map.camera.centerCoordinate.latitude == stoppedCamera.centerCoordinate.latitude)
        #expect(camera.map.camera.centerCoordinate.longitude == stoppedCamera.centerCoordinate.longitude)
    }

    @Test @MainActor func physicalPressAndDockHandoffsRestoreDiscardedDragViewports() async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.center(on: GeoCoordinate(latitude: 48.85837, longitude: 2.29448), animated: false)
        try await waitForSettled(camera)
        camera.touchContact(true)
        camera.pan(dx: 0.02, dy: 0)
        camera.claimTouchForPhysicalPress()
        try await waitForSettled(camera)
        #expect(camera.grid != nil)
        #expect(camera.snapshot?.isCurrent() == true)
        camera.touchContact(false)
        camera.touchContact(true)
        camera.pan(dx: 0.02, dy: 0)
        camera.setControlsPresented(true)
        try await waitForSettled(camera)
        #expect(camera.grid != nil)
        #expect(camera.snapshot?.isCurrent() == true)
        camera.setControlsPresented(false)
    }

    @Test @MainActor func noOpPanCannotInvalidateAnAlreadySettledViewport() async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.center(on: GeoCoordinate(latitude: 48.85837, longitude: 2.29448), animated: false)
        try await waitForSettled(camera)
        let revision = camera.revision
        camera.pan(dx: 0, dy: 0)
        camera.pan(dx: .nan, dy: 0)
        #expect(camera.grid != nil)
        #expect(camera.snapshot?.isCurrent() == true)
        #expect(camera.revision == revision)
    }

    @Test @MainActor func stoppedCameraCannotRepublishFromLateInputCallbacks() async throws {
        let camera = MapReviewCamera()
        defer { camera.stop() }
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.center(on: GeoCoordinate(latitude: 48.85837, longitude: 2.29448), animated: false)
        try await waitForSettled(camera)
        #expect(camera.grid != nil)
        camera.beginMovingInput()
        camera.touchContact(true)
        camera.pan(dx: 0.02, dy: 0)
        camera.stop()
        camera.touchContact(false)
        camera.setControlsPresented(false)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(camera.grid == nil)
        #expect(camera.snapshot == nil)
        camera.start()
        try await waitForSettled(camera)
        #expect(camera.grid != nil)
        #expect(camera.snapshot?.isCurrent() == true)
    }

    @Test @MainActor func synchronousCameraChangesPublishOneSettledViewport() async throws {
        let camera = MapReviewCamera()
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        camera.center(on: GeoCoordinate(latitude: 48.85837, longitude: 2.29448), animated: false)
        camera.zoom(inward: true, animated: false)
        try await waitForSettled(camera)
        #expect(camera.grid != nil)
        #expect(camera.snapshot?.isCurrent() == true)
        camera.stop()
    }
    @Test func streamingViewportClustersRetainPhotosAndCountsAcrossVisits() {
        let grid = MapReviewGrid(south: 31, north: 32, west: 121, east: 122, referenceLongitude: 121.5)
        var accumulator = MapReviewClusterAccumulator(grid: grid)
        for index in 0..<50_000 { accumulator.insert(photo(index, latitude: 31.24, longitude: 121.5)) }
        accumulator.insert(photo(50_000, latitude: 31.24, longitude: 121.5, placeID: "other-visit"))
        accumulator.insert(photo(50_001, latitude: 40, longitude: 120))
        #expect(accumulator.clusters.count == 1)
        #expect(accumulator.clusters.values.first?.count == 50_001)
        #expect(accumulator.clusters.values.first?.assetID != nil)
    }

    @Test @MainActor func selectReleaseHasOneOwnerAndDockKeepsItForButtons() {
        let camera = MapReviewCamera()
        var selections = 0
        camera.onSelect = { selections += 1 }
        camera.beginMovingInput()
        camera.receiveSelectPress(true, source: .uiKit)
        camera.receiveSelectPress(true, source: .hardware)
        camera.receiveSelectPress(false, source: .hardware)
        #expect(selections == 0)
        camera.receiveSelectPress(false, source: .uiKit)
        #expect(selections == 1)
        camera.setControlsPresented(true)
        camera.receiveSelectPress(true, source: .uiKit)
        camera.receiveSelectPress(false, source: .uiKit)
        #expect(selections == 1)
        camera.setControlsPresented(false)
        camera.receiveSelectPress(true, source: .uiKit)
        camera.receiveSelectPress(false, source: .uiKit)
        #expect(selections == 2)
        camera.onSelect = nil; camera.stop()
    }
    @Test @MainActor func reviewCameraAllowsStreetScaleWithoutChangingTheMainGlobe() {
        let camera = MapReviewCamera()
        camera.map.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let coordinate = GeoCoordinate(latitude: 48.85837, longitude: 2.29448)
        let cluster = MapReviewCluster(cell: MapReviewCell(column: 0, row: 0), count: 100, coordinate: coordinate,
                                       south: coordinate.latitude, north: coordinate.latitude,
                                       west: coordinate.longitude, east: coordinate.longitude, assetID: nil)
        camera.fit(cluster, animated: false)
        let initial = camera.map.camera.centerCoordinateDistance
        #expect(initial < 800_000)
        camera.zoom(inward: true, animated: false)
        let closer = camera.map.camera.centerCoordinateDistance
        #expect(closer < initial)
        camera.zoom(inward: false, animated: false)
        #expect(camera.map.camera.centerCoordinateDistance > closer)
        #expect(camera.map.camera.pitch == 0)
        let beforeSwitch = camera.map.camera.copy() as! MKMapCamera
        #expect(camera.style == .standard)
        camera.toggleStyle()
        #expect(camera.style == .satellite)
        camera.toggleStyle()
        #expect(camera.style == .standard)
        #expect(abs(camera.map.camera.centerCoordinate.latitude - beforeSwitch.centerCoordinate.latitude) < 0.000001)
        #expect(abs(camera.map.camera.centerCoordinate.longitude - beforeSwitch.centerCoordinate.longitude) < 0.000001)
        #expect(abs(camera.map.camera.centerCoordinateDistance - beforeSwitch.centerCoordinateDistance) < beforeSwitch.centerCoordinateDistance * 0.001)
        #expect(GlobeCameraState.minimumDistance < initial)
        camera.stop()
    }

    @Test func fiftyThousandAtOnePointHaveAnExactCountAndBoundedPages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-review-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = (0..<50_000).map { photo($0, latitude: 31.24, longitude: 121.5) }
        try await store.save(snapshot(photos))
        let grid = MapReviewGrid(south: 31, north: 32, west: 121, east: 122, referenceLongitude: 121.5)
        let sqlStart = ContinuousClock.now
        let clusters = try await store.mapReviewClusters(placeID: "visit", grid: grid)
        let sqlAggregation = sqlStart.duration(to: .now)
        #expect(clusters.count == 1)
        #expect(clusters[0].count == 50_000)
        #expect(clusters[0].assetID == photos[0].id)
        let reader = try await store.photoReadSnapshot()
        let operationID = UUID()
        let viewport = EarthViewport(center: photos[0].coordinate, angularRadius: 10)
        let countStart = ContinuousClock.now
        var streamedTotal = 0, offset = 0, batchCount = 0
        while true {
            let batch = try await reader.photoWallCountingCandidates(in: viewport, offset: offset, operationID: operationID)
            #expect(batch.records.count <= 512)
            streamedTotal += batch.records.count; batchCount += 1
            guard let next = batch.nextOffset else { break }
            offset = next
        }
        let sqlCount = countStart.duration(to: .now)
        #expect(streamedTotal == 50_000)
        #expect(batchCount == 98)
        print("MapReview SQL benchmark: records=50000 batches=\(batchCount) clusters=\(sqlAggregation) streamingCount=\(sqlCount)")
        let selection = MapReviewSelection(grid: grid, cells: Set(clusters.map(\.cell)))
        let page = try await store.mapReviewPage(placeID: "visit", selection: selection, offset: 0)
        #expect(page.records.count == 48)
        #expect(page.nextOffset == 48)
        #expect(page.records == Array(photos.prefix(48)))
        let next = try await store.mapReviewPage(placeID: "visit", selection: selection, offset: 48)
        #expect(next.records == Array(photos[48..<96]))
        let last = try await store.mapReviewPage(placeID: "visit", selection: selection, offset: 49_968)
        #expect(last.records.count == 32)
        #expect(last.nextOffset == nil)
        let removed = Set(photos.prefix(3).map(\.id))
        let revised = try await store.mapReviewClusters(placeID: "visit", grid: grid, excluding: removed)
        #expect(revised[0].count == 49_997)
        let filtered = try await store.mapReviewPage(placeID: "visit", selection: selection, offset: 0, excluding: removed)
        #expect(filtered.records.first == photos[3])
        #expect(try await store.mapReviewClusters(placeID: "other-visit", grid: grid).isEmpty)
    }

    @Test func cellsSplitWithZoomAndTheirUnionPagesOnlyTheirOwnPhotos() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-review-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = (0..<200).map { index in
            photo(index, latitude: 31.24, longitude: 121.50 + Double(index % 4) * 0.001)
        }
        try await store.save(snapshot(photos))
        let wide = MapReviewGrid(south: 31, north: 32, west: 121, east: 122, referenceLongitude: 121.5)
        #expect(try await store.mapReviewClusters(placeID: "visit", grid: wide).count == 1)
        let close = MapReviewGrid(south: 31.239, north: 31.241, west: 121.499, east: 121.504, referenceLongitude: 121.5)
        let clusters = try await store.mapReviewClusters(placeID: "visit", grid: close)
        #expect(clusters.count == 4)
        #expect(clusters.reduce(0) { $0 + $1.count } == 200)
        let demo = MapReviewCluster.demo(records: photos, grid: close)
        #expect(clusters.map(\.cell) == demo.map(\.cell))
        #expect(clusters.map(\.count) == demo.map(\.count))
        for (actual, expected) in zip(clusters, demo) {
            #expect(abs(actual.coordinate.latitude - expected.coordinate.latitude) < 0.000001)
            #expect(abs(actual.coordinate.longitude - expected.coordinate.longitude) < 0.000001)
        }
        let selection = MapReviewSelection(grid: close, cells: Set(clusters.prefix(2).map(\.cell)))
        let expected = photos.filter { selection.contains($0.coordinate) }
        var loaded: [PhotoAssetRecord] = [], offset = 0
        while true {
            let page = try await store.mapReviewPage(placeID: "visit", selection: selection, offset: offset)
            loaded += page.records
            guard let next = page.nextOffset else { break }
            offset = next
        }
        #expect(loaded == expected)
        #expect(loaded.count == 100)
    }

    @Test func dateLineBoundsSingletonAndSnapshotMembershipRemainCorrect() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-review-\(UUID()).sqlite")
        defer { cleanup(url) }
        let store = SQLiteTravelIndexStore(databaseURL: url)
        let photos = [photo(0, latitude: 0, longitude: 179.999), photo(1, latitude: 0, longitude: -179.999),
                      photo(2, latitude: 0, longitude: 170)]
        try await store.save(snapshot(photos))
        let reader = try await store.photoReadSnapshot()
        let grid = MapReviewGrid(south: -1, north: 1, west: 179.99, east: 180.01, referenceLongitude: 180, columns: 1, rows: 1)
        let clusters = try await reader.mapReviewClusters(placeID: "visit", grid: grid)
        #expect(clusters.count == 1)
        #expect(clusters[0].count == 2)
        #expect(abs(clusters[0].coordinate.longitude) > 179)
        #expect(clusters[0].east - clusters[0].west < 0.003)
        let selection = MapReviewSelection(grid: grid, cells: [clusters[0].cell])
        #expect(try await reader.mapReviewPage(placeID: "visit", selection: selection, offset: 0).records == Array(photos.prefix(2)))
        try await store.save(snapshot([photo(10, latitude: 10, longitude: 10)]))
        #expect(try await reader.mapReviewClusters(placeID: "visit", grid: grid)[0].count == 2)
        #expect(try await store.mapReviewClusters(placeID: "visit", grid: grid).isEmpty)
        let single = try await store.mapReviewClusters(placeID: "visit", grid: .world(around: 0))
        #expect(single[0].assetID == "photo-000010")
    }

    private func photo(_ index: Int, latitude: Double, longitude: Double, placeID: String = "visit") -> PhotoAssetRecord {
        PhotoAssetRecord(id: String(format: "photo-%06d", index), coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index / 8)),
                         pixelWidth: 1600, pixelHeight: 1000, isFavorite: false, placeID: placeID)
    }

    private func snapshot(_ photos: [PhotoAssetRecord]) -> TravelIndexSnapshot {
        let place = TravelPlace(id: "visit", name: "Fixture", country: nil, coordinate: photos[0].coordinate,
                                startDate: photos.last!.creationDate, endDate: photos[0].creationDate,
                                photoCount: photos.count, coverAssetID: photos[0].id)
        return TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(),
                                                     sourcePhotoCount: photos.count, locatedPhotoCount: photos.count,
                                                     places: [place], journeys: []), photos: photos)
    }

    @MainActor private func waitForSettled(_ camera: MapReviewCamera) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while camera.grid == nil || camera.snapshot?.isCurrent() != true {
            try #require(ContinuousClock.now < deadline, "The native map must publish a settled viewport")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor private func waitForPage(_ session: MapReviewSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while session.isLoading {
            try #require(ContinuousClock.now < deadline, "The viewport page must finish")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
