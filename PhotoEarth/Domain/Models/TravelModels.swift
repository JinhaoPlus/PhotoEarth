import Foundation

nonisolated struct GeoCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

nonisolated struct PhotoAssetRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let coordinate: GeoCoordinate
    let creationDate: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    var placeID: String? = nil
}

nonisolated struct TravelPlace: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var country: String?
    let coordinate: GeoCoordinate
    let startDate: Date
    let endDate: Date
    let photoCount: Int
    let coverAssetID: String?

    var year: Int { Calendar(identifier: .gregorian).component(.year, from: startDate) }

    var dateRangeText: String {
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "zh_CN")
        startFormatter.dateFormat = "yyyy年M月d日"
        let start = startFormatter.string(from: startDate)
        guard !Calendar.current.isDate(startDate, inSameDayAs: endDate) else { return start }
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "zh_CN")
        endFormatter.dateFormat = "M月d日"
        return start + " — " + endFormatter.string(from: endDate)
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
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let generatedAt: Date
    let sourcePhotoCount: Int
    let locatedPhotoCount: Int
    var places: [TravelPlace]
    var journeys: [TravelJourney]

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
