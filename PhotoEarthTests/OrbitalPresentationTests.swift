import MapKit
import Testing
import UIKit
@testable import PhotoEarth

struct OrbitalPresentationTests {
    @Test @MainActor func homeDriftStaysNearItsAnchorAndYieldsToExploration() throws {
        let model = GlobeExperienceModel()
        model.transitionCamera(to: GeoCoordinate(latitude: 57, longitude: 179.5),
                               distance: GlobeCameraState.orbitalDistance, animated: false)
        let anchor = model.camera
        let revision = model.settleRevision
        let stepsPerCycle = 512 // 64 seconds at one step every 0.125 seconds.
        for step in 1...stepsPerCycle {
            let next = try #require(model.advanceHomeDrift(from: model.camera, elapsed: 0.125))
            let offset = GlobeCameraState.normalizedLongitude(next.center.longitude - anchor.center.longitude)
            #expect(abs(offset) <= 2.400_001)
            #expect(next.center.latitude == anchor.center.latitude && next.distance == anchor.distance)
            if step == stepsPerCycle / 4 { #expect(abs(offset - 2.4) < 0.000_001) }
            if step == stepsPerCycle { #expect(abs(offset) < 0.000_001) }
        }
        #expect(model.settleRevision == revision)
        model.activate(initialCenter: nil) { _, _ in [] }
        #expect(model.advanceHomeDrift(from: model.camera, elapsed: 0.125) == nil)
        model.deactivate()
        model.setSceneActive(false)
        #expect(model.advanceHomeDrift(from: model.camera, elapsed: 0.125) == nil)
    }

    @Test func regionalAndOrbitalPresentationPreserveGestureCalibration() {
        #expect(GlobeCameraState(distance: GlobeCameraState.defaultDistance).navigationScale == 1)
        #expect(GlobeCameraState.orbitalDistance < GlobeCameraState.defaultDistance / 2)
        #expect(GlobeCameraState(distance: GlobeCameraState.orbitalDistance).presentationPitch == 35)
        #expect(GlobeCameraState(distance: GlobeCameraState.regionalDistance).presentationPitch == 0)
        #expect(GlobeCameraState(distance: GlobeCameraState.maximumDistance).presentationPitch == 0)
    }

    @Test func pitchChangesContinuouslyAcrossLogarithmicZoom() {
        let minimumDistance = GlobeCameraState.minimumDistance
        let maximumDistance = GlobeCameraState.maximumDistance
        var previous = GlobeCameraState(distance: minimumDistance).presentationPitch
        let steps = Int(ceil(log(maximumDistance / minimumDistance) / 0.004))
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let distance = step == steps ? maximumDistance
                : exp(log(minimumDistance) + fraction * log(maximumDistance / minimumDistance))
            let camera = GlobeCameraState(distance: distance)
            #expect(camera.distance == distance, "Pitch continuity must exercise the supported zoom range")
            let pitch = camera.presentationPitch
            #expect(pitch.isFinite && pitch >= 0 && pitch <= 35)
            #expect(abs(pitch - previous) < 0.8)
            previous = pitch
        }
    }

    @Test func polarApproachEasesOutBeforeNativePitchClamping() {
        var previous = 35.0
        for step in 0...300 {
            let latitude = 40 + Double(step) / 10
            let north = GlobeCameraState(
                center: GeoCoordinate(latitude: latitude, longitude: 20), distance: GlobeCameraState.orbitalDistance
            )
            let south = GlobeCameraState(
                center: GeoCoordinate(latitude: -latitude, longitude: 20), distance: GlobeCameraState.orbitalDistance
            )
            #expect(north.presentationPitch == south.presentationPitch)
            #expect(north.presentationPitch <= previous)
            #expect(previous - north.presentationPitch < 0.53)
            if latitude >= 55 { #expect(north.presentationPitch == 0) }
            previous = north.presentationPitch
        }
    }

    @Test(arguments: [0.0, 50.0, 55.0, 64.15, -33.87, -64.15]) @MainActor
    func reachableOrbitalAndRegionalCamerasKeepTheSameVisibleCenter(latitude: Double) async throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = MapKitEarthView.legalLayoutMargins(horizontalPresentationOffset: 0)
        let center = GeoCoordinate(latitude: latitude, longitude: 20)
        let coordinate = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        var previousNativeDistance = Double.infinity
        let distances = [
            GlobeCameraState.maximumDistance,
            GlobeCameraState.orbitalDistance,
            sqrt(GlobeCameraState.regionalDistance * GlobeCameraState.orbitalDistance),
            GlobeCameraState.regionalDistance,
        ]
        for distance in distances {
            let state = GlobeCameraState(center: center, distance: distance)
            #expect(state.distance == distance, "The native camera must receive an unclamped product state")
            map.setCamera(MKMapCamera(lookingAtCenter: coordinate,
                                      fromDistance: state.distance, pitch: state.presentationPitch, heading: 0), animated: false)
            map.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let point = map.convert(coordinate, toPointTo: map)
            let screenMidpoint = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
            let screenLocation = map.convert(screenMidpoint, toCoordinateFrom: map)
            let visibleCenter = GeoCoordinate(latitude: screenLocation.latitude, longitude: screenLocation.longitude)
            let visibleCenterProjection = map.convert(screenLocation, toPointTo: map)
            #expect(abs(point.x - 960) < 1)
            // tvOS 26.5 normalizes this 42 Mm fixture at ±64.15° to
            // 9.297 Mm / ±63.8011°. The 10 Mm, intermediate and regional
            // fixtures retain the requested center and remain strictly checked.
            let isNativeGlobalPolarLimit = distance == GlobeCameraState.maximumDistance && abs(latitude) > 60
            if !isNativeGlobalPolarLimit {
                #expect(abs(point.y - 540) < 1)
                #expect(GlobeMath.angularDistanceDegrees(from: center, to: visibleCenter) < 0.00001)
            }
            // At the farthest polar view MapKit can normalize both camera
            // distance and optical center. The query must still describe the
            // ground actually displayed at the screen center, with the same
            // strict projection tolerance used by closer camera states.
            #expect(visibleCenter.isValid)
            #expect(hypot(visibleCenterProjection.x - screenMidpoint.x,
                          visibleCenterProjection.y - screenMidpoint.y) < 1)
            let nativeDistance = map.camera.centerCoordinateDistance
            // MapKit also caps the world-scale distance at high latitudes.
            // Verify real zoom progress and the anchor rather than assuming the
            // native renderer accepts every orbital distance unchanged.
            #expect(nativeDistance > 0 && nativeDistance < previousNativeDistance)
            #expect(nativeDistance <= state.distance * 1.001)
            if distance == GlobeCameraState.regionalDistance {
                #expect(abs(nativeDistance - state.distance) < max(1, state.distance * 0.001))
            }
            previousNativeDistance = nativeDistance
            let viewport = try #require(MapViewportSampler.viewport(in: map))
            #expect(GlobeMath.angularDistanceDegrees(from: visibleCenter, to: viewport.center) < 0.00001)
            let nativeCenter = map.camera.centerCoordinate
            #expect(GlobeMath.angularDistanceDegrees(
                from: GeoCoordinate(latitude: nativeCenter.latitude, longitude: nativeCenter.longitude),
                to: viewport.center
            ) < 0.00001)
            #expect(viewport.contains(center), "The requested anchor remains on the visible surface at the native limit")
            #expect(viewport.angularRadius > 0 && viewport.angularRadius <= 94)
            let visibility = try #require(viewport.visibilityCap)
            var visibleSampleCount = 0
            for x in [240.0, 960, 1_680] {
                for y in [270.0, 540, 810] {
                    let pixel = CGPoint(x: x, y: y)
                    let ground = map.convert(pixel, toCoordinateFrom: map)
                    let coordinate = GeoCoordinate(latitude: ground.latitude, longitude: ground.longitude)
                    guard coordinate.isValid else { continue }
                    let projected = map.convert(ground, toPointTo: map)
                    guard hypot(projected.x - x, projected.y - y) < 1 else { continue }
                    visibleSampleCount += 1
                    #expect(visibility.contains(coordinate), "Native visible ground must survive back-face filtering")
                    #expect(viewport.contains(coordinate), "Native visible ground must survive the complete viewport filter")
                }
            }
            #expect(visibleSampleCount > 0, "Visibility checks must include actual surface samples")
            if distance == GlobeCameraState.regionalDistance {
                #expect(viewport.angularRadius < MapEarthGeometry.horizonAngle(distance: nativeDistance))
            }
        }
    }

    @Test func geometricTiltedBoundsStayFiniteAndContainTheOverheadCap() {
        // Pure spherical geometry remains valid below the app's camera limit.
        for distance in [800.0, 1_000_000, 10_000_000, 30_000_000] {
            let overhead = MapEarthGeometry.horizonAngle(distance: distance)
            let tilted = MapEarthGeometry.surfaceVisibilityRadius(distance: distance, pitch: 35)
            #expect(tilted >= overhead && tilted <= 94)
        }
        #expect(MapEarthGeometry.surfaceVisibilityRadius(distance: .nan, pitch: 35) == 2)
    }
}
