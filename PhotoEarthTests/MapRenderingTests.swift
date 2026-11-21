import Foundation
import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct MapRenderingTests {
    @Test @MainActor func homeFrameBridgesOnlyTheSameRenderedHomeView() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        host.view.addSubview(map)
        window.isHidden = false
        defer { window.isHidden = true }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        let home = GlobeCameraState()
        let city = GlobeCameraState(center: home.center, distance: GlobeCameraState.regionalDistance)
        let frame = HomeGlobeFrame()
        func update(_ context: HomeGlobeFrame.Context, _ camera: GlobeCameraState, ready: Bool = false) -> Bool {
            frame.update(in: map, context: context, camera: camera, canCapture: ready)
        }

        #expect(!update(.home("library"), home))
        #expect(!update(.away("library"), city))
        #expect(!update(.home("library"), home), "An unfinished initial render cannot cover home")
        #expect(!update(.away("library"), city, ready: true))
        #expect(update(.home("library"), home))
        frame.show(in: map)
        #expect(frame.isShowing)
        frame.didRender(camera: city)
        #expect(frame.isShowing)
        #expect(!update(.away("library"), city))
        #expect(!frame.isShowing)
        #expect(update(.home("library"), home), "A fast second visit can reuse the original frame")
        frame.show(in: map)
        frame.didRender(camera: home)
        #expect(!frame.isShowing)

        #expect(!update(.away("library"), city, ready: true))
        #expect(!update(.home("library"), city), "A different home camera needs its own render")
        #expect(!update(.away("library"), home, ready: true))
        #expect(!update(.home("new library"), city))
        #expect(!update(.away("new library"), home, ready: true))
        #expect(!update(.inactive, home))
        #expect(!update(.home("new library"), city))

        frame.didRender(camera: city)
        var drifting = city
        drifting.rotate(longitudeDelta: 0.015, latitudeDelta: 0)
        #expect(!frame.update(in: map, context: .home("new library"), camera: drifting,
                              canCapture: false, isDriftStep: true))
        #expect(!update(.away("new library"), home))
        #expect(update(.home("new library"), drifting), "The last small orbit step can return before MapKit issues another render callback")
    }

    @Test(arguments: [800_000.0, 10_000_000, 42_000_000]) @MainActor
    func styleRoundTripPreservesTheNativeCameraAndViewport(distance: Double) async throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        defer { coordinator.cancelPendingSnapshot() }
        let camera = GlobeCameraState(center: GeoCoordinate(latitude: 48.85837, longitude: 2.29448), distance: distance)
        func apply(_ style: PhotoMapStyle, revision: Int) {
            coordinator.update(map, places: [], horizontalPresentationOffset: 0, contentRevision: 0,
                camera: camera, isManipulating: false, showsUserLocation: false, settleRevision: revision,
                mapStyle: style, onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        }
        apply(.satellite, revision: 0)
        let original = map.camera.copy() as! MKMapCamera
        for (index, style) in [PhotoMapStyle.standard, .satellite].enumerated() {
            let oldProjection = try #require(MapViewportSampler.photoSnapshot(in: map))
            apply(style, revision: index + 1)
            map.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(abs(map.camera.centerCoordinate.latitude - original.centerCoordinate.latitude) < 0.00001)
            #expect(abs(map.camera.centerCoordinate.longitude - original.centerCoordinate.longitude) < 0.00001)
            #expect(abs(map.camera.centerCoordinateDistance - original.centerCoordinateDistance) < max(1, original.centerCoordinateDistance * 0.001))
            #expect(abs(map.camera.pitch - original.pitch) < 0.01)
            #expect(MapViewportSampler.photoSnapshot(in: map)?.isCurrent() == true)
            #expect(!oldProjection.isCurrent(), "A style change expires the old projection even at the same camera")
            if style == .standard {
                let configuration = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
                #expect(configuration.elevationStyle == .realistic)
                #expect(configuration.pointOfInterestFilter == .excludingAll)
                #expect(!configuration.showsTraffic)
                #expect(MapViewportSampler.viewport(in: map)?.visibilityCap == nil)
            } else { #expect(map.preferredConfiguration is MKImageryMapConfiguration) }
        }
    }

    @Test @MainActor func changingStyleInvalidatesPhotosWithoutChangingTheRequestedCamera() {
        let experience = GlobeExperienceModel()
        let camera = experience.camera
        let revision = experience.settleRevision
        #expect(experience.mapStyle == .satellite)
        experience.toggleMapStyle()
        #expect(experience.mapStyle == .standard)
        #expect(experience.camera == camera)
        #expect(experience.settleRevision == revision + 1)
        #expect(!experience.photoBatchReady)
        experience.toggleMapStyle()
        #expect(experience.mapStyle == .satellite)
        #expect(experience.camera == camera)
    }
    @Test func smallDenseLibrariesStillRespectTheGeographicCellBudget() {
        let places = (0..<20).map { index in
            place("dense-\(index)", latitude: 31.2, longitude: 121.4, order: index)
        }

        let selected = MapPlaceLOD.representatives(from: places, limit: 180)

        #expect(selected.map(\.id) == ["dense-19", "dense-18"])
        #expect(MapPlaceLOD.representatives(from: places.reversed(), limit: 180) == selected)
    }

    @Test func markerBudgetRejectsInvalidCoordinatesAndDuplicateIDs() {
        let valid = place("valid", latitude: 35, longitude: 139, order: 1)
        let other = place("other", latitude: -34, longitude: 151, order: 0)
        let invalid = place("invalid", latitude: .nan, longitude: 0, order: 2)
        let places = [valid, valid, invalid, other]

        #expect(MapPlaceLOD.representatives(from: places, limit: 0).isEmpty)
        #expect(MapPlaceLOD.representatives(from: places, limit: -1).isEmpty)
        #expect(MapPlaceLOD.representatives(from: places, limit: 1).map(\.id) == ["valid"])
        #expect(MapPlaceLOD.representatives(from: places, limit: 180).map(\.id) == ["valid", "other"])
    }

    @Test func dateLineUsesOneCellForBothRepresentationsOfTheSameMeridian() {
        let places = [
            place("west", latitude: 10, longitude: -180, order: 1),
            place("east", latitude: 10, longitude: 180, order: 2),
            place("nearby", latitude: 10.1, longitude: -179.9, order: 3),
        ]

        let selected = MapPlaceLOD.representatives(from: places, limit: 180)

        #expect(selected.map(\.id) == ["nearby", "east"])
    }

    @Test func visibleHorizonIsFiniteMonotonicAndNeverIncludesTheBackOfTheEarth() {
        let distances = [1_600_000.0, 7_500_000, 23_500_000, 26_000_000, 42_000_000]
        let angles = distances.map(MapEarthGeometry.horizonAngle)

        #expect(angles.allSatisfy { $0.isFinite && $0 > 0 && $0 < 90 })
        #expect(zip(angles, angles.dropFirst()).allSatisfy { $0 < $1 })
        #expect(MapEarthGeometry.horizonAngle(distance: 0) == 2)
        #expect(MapEarthGeometry.horizonAngle(distance: .infinity) == 2)
        #expect(MapEarthGeometry.horizonAngle(distance: .nan) == 2)
    }

    @Test func narrowAngularViewportPaddingTracksPixelsInsteadOfAddingFixedDegrees() throws {
        // This exercises sampling precision independently of the product's
        // camera limits; no GlobeCameraState or native camera is constructed.
        let horizon = MapEarthGeometry.horizonAngle(distance: 5_000)
        let radius = try #require(MapEarthGeometry.viewportRadius(
            sampledAngles: [0.006, 0.011, 0.015, 0.008],
            horizonAngle: horizon,
            viewportDiagonal: hypot(1_920, 1_080)
        ))

        #expect(radius >= 0.015)
        #expect(radius < 0.0151)
        #expect(radius < horizon / 100)
        #expect(MapEarthGeometry.viewportRadius(
            sampledAngles: [0, .nan, .infinity], horizonAngle: horizon, viewportDiagonal: 2_200
        ) == nil)
        #expect(MapEarthGeometry.viewportRadius(
            sampledAngles: [horizon], horizonAngle: horizon, viewportDiagonal: 2_200
        ) == horizon)
    }

    @Test @MainActor
    func ornamentMarginsAndReachableZoomKeepUnlabeledImageryCentered() async throws {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        mapView.insetsLayoutMarginsFromSafeArea = false
        let coordinate = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        let marker = place("Tokyo", latitude: coordinate.latitude, longitude: coordinate.longitude)
        let coordinator = MapKitEarthView.Coordinator(onViewportSettled: { _ in }, onUserLocationUpdate: { _ in })
        defer { coordinator.cancelPendingSnapshot() }
        var referenceProjectionByDistance: [Double: CGPoint] = [:]
        let distances = [
            GlobeCameraState.maximumDistance,
            GlobeCameraState.orbitalDistance,
            sqrt(GlobeCameraState.regionalDistance * GlobeCameraState.orbitalDistance),
            GlobeCameraState.regionalDistance,
        ]

        for offset in [230.4, 115.2, 0.0] {
            mapView.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: offset)
            for distance in distances {
                let camera = GlobeCameraState(center: marker.coordinate, distance: distance)
                #expect(camera.distance == distance, "Every framing sample must be reachable without clamping")
                coordinator.update(
                    mapView, places: [marker], horizontalPresentationOffset: offset,
                    contentRevision: 0,
                    camera: camera,
                    isManipulating: false, showsUserLocation: false, settleRevision: 0,
                    onViewportSettled: { _ in }, onUserLocationUpdate: { _ in }
                )
                mapView.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))

                // The complete supported zoom range must retain pure imagery
                // and leave geographic labels to the photo interface.
                #expect(mapView.preferredConfiguration is MKImageryMapConfiguration)
                #expect(mapView.annotations.count == 1)
                #expect(mapView.annotations.allSatisfy { ($0.title ?? nil) == nil })

                // MapKit normalizes globe-scale distances. The closest regional
                // framing must still reach the product's configured boundary.
                if distance == GlobeCameraState.regionalDistance {
                    #expect(abs(mapView.camera.centerCoordinateDistance - distance) < max(1, distance * 0.01))
                }
                let projected = mapView.convert(coordinate, toPointTo: mapView)
                #expect(abs(projected.x - mapView.bounds.midX) < 1)
                #expect(abs(projected.y - mapView.bounds.midY) < 1)

                let probe = CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude + 10 * camera.navigationScale
                )
                let probePoint = mapView.convert(probe, toPointTo: mapView)
                if let reference = referenceProjectionByDistance[distance] {
                    // Changing only the legal margins during a framing flight
                    // must not secretly change the map's projection scale.
                    #expect(hypot(probePoint.x - reference.x, probePoint.y - reference.y) < 1)
                } else {
                    referenceProjectionByDistance[distance] = probePoint
                }
            }
        }

        let viewport = try #require(MapViewportSampler.viewport(in: mapView))
        #expect(viewport.angularRadius > 0)
        #expect(viewport.angularRadius < MapEarthGeometry.horizonAngle(
            distance: mapView.camera.centerCoordinateDistance
        ))
        #expect(GlobeMath.angularDistanceDegrees(
            from: viewport.center,
            to: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ) < 0.00001)
    }

    private func place(
        _ id: String,
        latitude: Double,
        longitude: Double,
        order: Int = 0
    ) -> TravelPlace {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(order))
        return TravelPlace(
            id: id,
            name: id,
            country: nil,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            startDate: date,
            endDate: date,
            photoCount: 1,
            coverAssetID: nil
        )
    }
}
