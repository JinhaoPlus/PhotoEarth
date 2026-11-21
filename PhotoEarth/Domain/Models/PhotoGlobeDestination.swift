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

    var previewCamera: GlobeCameraState {
        // Center the real photo, including at high latitude. Moving this view
        // toward the equator can push MapKit's annotation outside the miniature.
        // Native camera limits may show a close polar globe instead of a full disc.
        GlobeCameraState(center: coordinate, distance: 20_000_000).mapConstrained()
    }

    var marker: TravelPlace {
        TravelPlace(id: Self.markerID, name: "", country: nil, coordinate: coordinate,
                    startDate: date, endDate: date, photoCount: 1, coverAssetID: nil)
    }
}
