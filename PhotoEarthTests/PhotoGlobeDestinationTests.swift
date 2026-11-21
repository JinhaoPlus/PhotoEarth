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
        #expect(destination.previewCamera.center == photo.coordinate)
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

    @Test(arguments: [0.0, 35, 64, 83, -34, -83]) @MainActor
    func stationaryMiniatureProjectsTheActualPhotoInsideItsBounds(latitude: Double) async throws {
        let destination = try #require(PhotoGlobeDestination(record: record(latitude: latitude, longitude: 179)))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 252))
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let camera = destination.previewCamera
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
        let controller = UIHostingController(rootView: PhotoLocationGlobe(destination: destination, placeTitle: "示例地点", open: {}))
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
        #expect(!map.isUserInteractionEnabled && !map.showsUserLocation)
        #expect(map.annotations.isEmpty)
        let marker = preview.locationLight
        #expect(marker.image?.size.width == 64)
        #expect(marker.alpha == 1 && !marker.isHidden)
        #expect(map.bounds.contains(marker.center))
        let nativePoint = map.convert(CLLocationCoordinate2D(latitude: destination.coordinate.latitude,
                                                             longitude: destination.coordinate.longitude), toPointTo: preview)
        #expect(hypot(marker.center.x - nativePoint.x, marker.center.y - nativePoint.y) < 1)
    }

    private func record(latitude: Double, longitude: Double, placeID: String? = nil) -> PhotoAssetRecord {
        PhotoAssetRecord(id: "synthetic-photo", coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                         creationDate: Date(timeIntervalSince1970: 1234), pixelWidth: 4000, pixelHeight: 3000,
                         isFavorite: false, placeID: placeID)
    }
}
