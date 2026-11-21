import Foundation
import simd

/// Groups chronological photos by city and time using constant memory per visit.
/// The caller stores membership using `position`, then the final ID.
nonisolated struct StreamingTravelClusterer {
    static let publicationVersion = 1
    let configuration: TravelClusteringConfiguration
    private(set) var position = 0
    private var count = 0
    private var x = 0.0, y = 0.0, z = 0.0
    private var firstCoordinate: GeoCoordinate?
    private var firstDate = Date.distantPast
    private var lastDate = Date.distantPast
    private var seed = ""
    private var cover: PhotoAssetRecord?
    private var visitLabel: PlaceDisplayLabel?

    init(configuration: TravelClusteringConfiguration = .init()) {
        self.configuration = configuration
    }

    private var center: GeoCoordinate {
        GeoCoordinate(latitude: atan2(z, sqrt(x*x + y*y)) * 180 / .pi,
                      longitude: atan2(y, x) * 180 / .pi)
    }

    mutating func append(_ record: PhotoAssetRecord, label: PlaceDisplayLabel? = nil) -> TravelPlace? {
        var completed: TravelPlace?
        if count > 0, record.creationDate.timeIntervalSince(lastDate) > configuration.maximumPlaceGap
            || !sameDestination(as: label, at: record.coordinate) {
            completed = place
            position += 1
            count = 0; x = 0; y = 0; z = 0; cover = nil
        }
        if count == 0 {
            firstCoordinate = record.coordinate
            firstDate = record.creationDate
            seed = record.id
            visitLabel = label
        }
        seed = min(seed, record.id)
        lastDate = record.creationDate
        if visitLabel?.offlinePlaceID == nil {
            let latitude = record.coordinate.latitude * .pi / 180
            let longitude = record.coordinate.longitude * .pi / 180
            x += cos(latitude) * cos(longitude)
            y += cos(latitude) * sin(longitude)
            z += sin(latitude)
        }
        count += 1
        if cover == nil || score(record) > score(cover!) { cover = record }
        return completed
    }

    private func sameDestination(as label: PlaceDisplayLabel?, at coordinate: GeoCoordinate) -> Bool {
        let city = visitLabel?.offlinePlaceID
        guard city == label?.offlinePlaceID, visitLabel?.regionCode == label?.regionCode else { return false }
        return city != nil || GlobeMath.distanceKilometers(from: center, to: coordinate) <= configuration.placeRadiusKilometers
    }

    var place: TravelPlace? {
        guard count > 0, let firstCoordinate else { return nil }
        return TravelPlace(id: "place-\(Self.stableHash(seed))", name: visitLabel?.city ?? "",
                           country: visitLabel?.country, regionCode: visitLabel?.regionCode,
                           offlinePlaceID: visitLabel?.offlinePlaceID,
                           coordinate: firstCoordinate, startDate: firstDate, endDate: lastDate,
                           photoCount: count, coverAssetID: cover?.id)
    }

    private func score(_ record: PhotoAssetRecord) -> Int64 {
        let orientation: Int64 = record.pixelWidth >= record.pixelHeight ? 2_000_000_000 : 0
        let favorite: Int64 = record.isFavorite ? 4_000_000_000 : 0
        return orientation + favorite + min(Int64(record.pixelWidth) * Int64(record.pixelHeight), 1_999_999_999)
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    static func journeys(_ places: [TravelPlace], configuration: TravelClusteringConfiguration) -> [TravelJourney] {
        var result: [TravelJourney] = []
        var start = 0
        while start < places.count {
            var end = start + 1
            while end < places.count,
                  places[end].startDate.timeIntervalSince(places[end - 1].endDate) <= configuration.maximumJourneyGap { end += 1 }
            let first = places[start], last = places[end - 1]
            result.append(TravelJourney(id: "journey-\(stableHash(first.id))", title: "",
                                        startDate: first.startDate, endDate: last.endDate,
                                        placeIDs: places[start..<end].map(\.id)))
            start = end
        }
        return result
    }
}
