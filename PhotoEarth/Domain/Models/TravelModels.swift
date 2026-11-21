import Foundation

nonisolated struct GeoCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// The presentation carried by a Photos asset. Raw values are persisted in the
/// derived SQLite index, so append new cases instead of reordering them.
nonisolated enum PhotoMediaKind: Int, Codable, Hashable, Sendable {
    case photo = 0
    case livePhoto = 1
    case video = 2

    var isPlayable: Bool { self != .photo }
}

nonisolated struct PhotoAssetRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let coordinate: GeoCoordinate
    let creationDate: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let mediaKind: PhotoMediaKind
    let duration: TimeInterval
    let altitudeMeters: Double?
    let horizontalAccuracyMeters: Double?
    let verticalAccuracyMeters: Double?
    var placeID: String?

    init(
        id: String,
        coordinate: GeoCoordinate,
        creationDate: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool,
        mediaKind: PhotoMediaKind = .photo,
        duration: TimeInterval = 0,
        placeID: String? = nil,
        altitudeMeters: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        verticalAccuracyMeters: Double? = nil
    ) {
        self.id = id
        self.coordinate = coordinate
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.mediaKind = mediaKind
        self.duration = mediaKind == .video && duration.isFinite ? max(0, duration) : 0
        self.placeID = placeID
        self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
    }
}

nonisolated struct TravelPlace: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var country: String?
    var regionCode: String? = nil
    var offlinePlaceID: String? = nil
    let coordinate: GeoCoordinate
    let startDate: Date
    let endDate: Date
    let photoCount: Int
    let coverAssetID: String?

    var year: Int { Calendar(identifier: .gregorian).component(.year, from: startDate) }

    var dateRangeText: String {
        AppLocalization.dateRange(from: startDate, to: endDate)
    }
}

nonisolated struct TravelJourney: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: String
    let startDate: Date
    let endDate: Date
    let placeIDs: [String]
}

nonisolated struct TravelIndex: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 6

    let schemaVersion: Int
    let generatedAt: Date
    let sourcePhotoCount: Int
    let locatedPhotoCount: Int
    var places: [TravelPlace]
    var journeys: [TravelJourney]
    /// Raw located count remains available even when every visit is filtered.
    var hiddenTransitPhotoCount: Int = 0
    var transitFilteringApplied: Bool = false
    var transitRevision: String? = nil
    var contentRevision: String { "\(generatedAt.timeIntervalSince1970):\(transitRevision ?? "raw")" }
    var visiblePhotoCount: Int { locatedPhotoCount - hiddenTransitPhotoCount }

    var isCompatible: Bool { schemaVersion == Self.currentSchemaVersion }

    func place(id: String?) -> TravelPlace? {
        guard let id else { return nil }
        return places.first { $0.id == id }
    }
}

/// The complete result of a PhotoKit scan. Only `index` is loaded at app launch;
/// individual photo rows remain in SQLite until a viewport or place requests them.
nonisolated struct TravelIndexSnapshot: Equatable, Sendable {
    let index: TravelIndex
    let photos: [PhotoAssetRecord]
}
