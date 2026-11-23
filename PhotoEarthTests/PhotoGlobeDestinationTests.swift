import Foundation
import MapKit
import SwiftUI
import Testing
import UIKit
@testable import PhotoEarth

struct PhotoGlobeDestinationTests {
    @Test func aPhotoDestinationUsesActualGPSWithoutRequiringPlaceLabels() throws {
        let photo = record(latitude: 35.6, longitude: 139.7, placeID: "tokyo-visit")
        let destination = try #require(PhotoGlobeDestination(record: photo))
        #expect(destination.coordinate == photo.coordinate)
        #expect(destination.placeID == "tokyo-visit")
        #expect(destination.marker.coordinate == photo.coordinate)
        #expect(destination.camera.center == photo.coordinate)
        #expect(destination.camera.distance == GlobeCameraState.regionalDistance)
        #expect(destination.marker.coverAssetID == nil)
        #expect(destination.explorationOpeningCamera.center == photo.coordinate)
        #expect(destination.miniatureCamera(from: nil).center == photo.coordinate)
        #expect(destination.miniatureCamera(from: nil).distance == 2_500)
        #expect(PhotoGlobeDestination(record: record(latitude: .nan, longitude: 0)) == nil)
        #expect(PhotoGlobeDestination(record: record(latitude: 20, longitude: 181)) == nil)
    }

    @Test func photoMarkerSurvivesDenseLODWithoutJoiningSavedPlaceMembership() throws {
        let destination = try #require(PhotoGlobeDestination(record: record(latitude: 35, longitude: 139)))
        let places = (0..<500).map { index in
            TravelPlace(id: "synthetic-\(index)", name: "", country: nil, coordinate: destination.coordinate,
                        startDate: .distantFuture, endDate: .distantFuture, photoCount: 100, coverAssetID: nil)
        }
        let visible = MapPlaceLOD.representatives(from: places + [destination.marker], limit: 180,
                                                 preferredPlaceID: PhotoGlobeDestination.markerID)
        #expect(visible.first?.id == PhotoGlobeDestination.markerID)
        #expect(visible.count == 2)
        #expect(places.allSatisfy { $0.id != PhotoGlobeDestination.markerID })
    }

    @Test(arguments: [0.0, 35, 64, 83, 83.1, -34, -83, -83.1]) @MainActor
    func stationaryMiniatureProjectsTheActualPhotoInsideItsBounds(latitude: Double) async throws {
        let destination = try #require(PhotoGlobeDestination(record: record(latitude: latitude, longitude: 179)))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 208, height: 152))
        map.preferredConfiguration = PhotoMapStyle.standard.configuration(realisticTerrain: false)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let camera = destination.miniatureCamera(from: nil)
        map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: camera.center.latitude,
                                                                          longitude: camera.center.longitude),
                                 fromDistance: camera.distance, pitch: camera.presentationPitch, heading: 0), animated: false)
        map.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let point = map.convert(CLLocationCoordinate2D(latitude: destination.coordinate.latitude,
                                                        longitude: destination.coordinate.longitude), toPointTo: map)
        #expect(point.x.isFinite && point.y.isFinite)
        #expect(map.bounds.insetBy(dx: 12, dy: 12).contains(point))
    }

    @Test @MainActor func miniatureShowsOneLightAtNativePhotoProjectionWithoutMapInput() async throws {
        let destination = try #require(PhotoGlobeDestination(record: record(latitude: 64, longitude: -22)))
        let controller = UIHostingController(rootView: PhotoLocationGlobe(destination: destination, placeTitle: nil, open: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        func findMap(_ view: UIView) -> PhotoLocationMapView? {
            if let map = view as? PhotoLocationMapView { return map }
            return view.subviews.lazy.compactMap { findMap($0) }.first
        }
        let preview = try #require(findMap(controller.view))
        let map = preview.mapView
        #expect(map.preferredConfiguration is MKStandardMapConfiguration)
        #expect(map.overlays.isEmpty)
        #expect(abs(map.camera.centerCoordinateDistance - 2_500) < 25)
        #expect(!map.isUserInteractionEnabled && !map.showsUserLocation)
        #expect(map.annotations.isEmpty)
        #expect(map.transform.a < 1 && map.transform.a == map.transform.d)
        #expect(map.frame.equalTo(preview.bounds))
        let marker = preview.locationLight
        #expect(marker.image?.size.width == 64)
        #expect(marker.alpha == 1 && !marker.isHidden)
        #expect(map.bounds.contains(marker.center))
        let nativePoint = map.convert(CLLocationCoordinate2D(latitude: destination.coordinate.latitude,
                                                             longitude: destination.coordinate.longitude), toPointTo: preview)
        #expect(hypot(marker.center.x - nativePoint.x, marker.center.y - nativePoint.y) < 1)
    }

    @Test(arguments: [PhotoLocationMap.Style.detail, .slideshow]) @MainActor
    func nearbyShotsMoveAcrossTheInsetWithoutReframingRepeatedGPS(style: PhotoLocationMap.Style) throws {
        let start = try #require(PhotoGlobeDestination(record: record(latitude: 41.39, longitude: 2.16)))
        let next = try #require(PhotoGlobeDestination(record: record(latitude: 41.3918, longitude: 2.16)))
        let preview = PhotoLocationMapView(style: style)
        preview.frame.size = style == .detail ? CGSize(width: 208, height: 152) : CGSize(width: 280, height: 176)
        func show(_ photo: PhotoGlobeDestination, visible: Bool = true) {
            preview.configure(photo, isVisible: visible, allowsMotion: false)
            preview.layoutIfNeeded()
        }
        show(start)
        let original = CLLocationCoordinate2D(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)
        let wide = GlobeCameraState(center: next.coordinate, distance: 100_000)
        preview.mapView.setCamera(wide.nativeCamera, animated: false)
        let atOldScale = preview.mapView.convert(original, toPointTo: preview)
        show(next)
        let atNewScale = preview.mapView.convert(original, toPointTo: preview)
        let center = preview.locationLight.center
        #expect(abs(atOldScale.y - center.y) < 3)
        #expect(abs(atNewScale.y - center.y) > 25)
        #expect((475...525).contains(preview.mapView.camera.centerCoordinateDistance))
        let settled = preview.mapView.camera.centerCoordinateDistance
        show(start, visible: false)
        show(next)
        #expect(abs(preview.mapView.camera.centerCoordinateDistance - settled) < 1)
        #expect(!preview.locationLight.isHidden)
    }

    @Test func crossCityStepsAreCappedAndDatelineNeighborsStayLocal() throws {
        let start = GeoCoordinate(latitude: 0, longitude: 179.999)
        let near = try #require(PhotoGlobeDestination(record: record(latitude: 0, longitude: -179.999)))
        let far = try #require(PhotoGlobeDestination(record: record(latitude: 0, longitude: 2)))
        #expect((500...600).contains(near.miniatureCamera(from: start).distance))
        #expect(far.miniatureCamera(from: start).distance == 25_000)
    }

    @Test(arguments: [PhotoLocationMap.Style.detail, .slideshow]) @MainActor
    func miniatureTravelsBetweenPhotosAndHonorsReducedMotion(style: PhotoLocationMap.Style) async throws {
        let start = try #require(PhotoGlobeDestination(record: record(latitude: 35, longitude: 158)))
        let next = try #require(PhotoGlobeDestination(record: record(latitude: 34, longitude: -170)))
        let last = try #require(PhotoGlobeDestination(record: record(latitude: 36, longitude: 140)))
        let preview = PhotoLocationMapView(style: style)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 280, height: 176))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        preview.frame = controller.view.bounds
        controller.view.addSubview(preview)

        func distance(from destination: PhotoGlobeDestination) -> Double {
            let center = preview.mapView.centerCoordinate
            return GlobeMath.angularDistanceDegrees(from: destination.coordinate,
                to: GeoCoordinate(latitude: center.latitude, longitude: center.longitude))
        }
        preview.configure(start, isVisible: true, allowsMotion: true)
        preview.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(distance(from: start) < 0.05)
        #expect(preview.mapView.preferredConfiguration is MKStandardMapConfiguration)
        #expect(preview.mapView.overlays.isEmpty)
        #expect(abs(preview.mapView.camera.centerCoordinateDistance - 2_500) < 25)
        preview.configure(next, isVisible: false, allowsMotion: true)
        preview.layoutIfNeeded()
        #expect(distance(from: start) < 0.05 && preview.locationLight.isHidden)

        preview.configure(next, isVisible: true, allowsMotion: true)
        preview.layoutIfNeeded()
        var sawIntermediatePosition = false
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while clock.now < deadline && distance(from: next) > 0.05 {
            if distance(from: start) > 0.1 && distance(from: next) > 0.1 {
                sawIntermediatePosition = true
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(sawIntermediatePosition && distance(from: next) < 0.05)
        #expect(!preview.locationLight.isHidden)
        preview.configure(start, isVisible: true, allowsMotion: true)
        preview.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let interruptedCenter = preview.mapView.centerCoordinate
        preview.configure(last, isVisible: true, allowsMotion: true)
        preview.layoutIfNeeded()
        #expect(abs(preview.mapView.centerCoordinate.latitude - interruptedCenter.latitude) < 0.01)
        #expect(abs(preview.mapView.centerCoordinate.longitude - interruptedCenter.longitude) < 0.01)
        try await Task.sleep(for: .milliseconds(120))
        #expect(distance(from: last) > 0.1)
        preview.configure(last, isVisible: true, allowsMotion: false)
        preview.layoutIfNeeded()
        #expect(distance(from: last) < 0.05)
        try await Task.sleep(for: .milliseconds(450))
        #expect(distance(from: last) < 0.05)
    }

    private func record(latitude: Double, longitude: Double, placeID: String? = nil) -> PhotoAssetRecord {
        PhotoAssetRecord(id: "synthetic-photo", coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: 1234), pixelWidth: 4000, pixelHeight: 3000,
                         isFavorite: false, placeID: placeID)
    }
}
