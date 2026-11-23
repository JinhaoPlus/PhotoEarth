import Foundation

/// A photo opens the globe at its actual GPS, independently of its cluster's
/// city label. This transient marker never becomes part of the saved index.
nonisolated struct PhotoGlobeDestination: Equatable {
    static let markerID = "photo-location-highlight"
    let coordinate: GeoCoordinate
    let date: Date
    let placeID: String?

    init?(record: PhotoAssetRecord) {
        guard record.coordinate.isValid else { return nil }
        coordinate = record.coordinate
        date = record.creationDate
        placeID = record.placeID
    }

    var camera: GlobeCameraState {
        GlobeCameraState(center: coordinate, distance: GlobeCameraState.regionalDistance).mapConstrained()
    }

    /// Frame the last step between visible photos, keeping the new photo at the center.
    func miniatureCamera(from previous: GeoCoordinate?) -> GlobeCameraState {
        let distance = previous.map {
            let meters = GlobeMath.distanceKilometers(from: $0, to: coordinate) * 1_000
            // A local step should move a noticeable fraction of the inset.
            return min(25_000, max(400, meters * 2.5))
        } ?? 2_500
        var camera = GlobeCameraState(center: coordinate, distance: distance).mapConstrained()
        if camera.center.latitude != coordinate.latitude {
            // When MapKit limits the center near a pole, leave enough room for the real GPS light.
            let offset = GlobeMath.distanceKilometers(from: camera.center, to: coordinate) * 1_000
            camera.distance = min(camera.maximumMapDistance, max(camera.distance, offset * 8))
        }
        return camera
    }

    var explorationOpeningCamera: GlobeCameraState {
        // Enter the full-screen exploration from orbit over the photo.
        GlobeCameraState(center: coordinate, distance: 20_000_000).mapConstrained()
    }

    var marker: TravelPlace {
        TravelPlace(id: Self.markerID, name: "", country: nil, coordinate: coordinate,
                    startDate: date, endDate: date, photoCount: 1, coverAssetID: nil)
    }
}
