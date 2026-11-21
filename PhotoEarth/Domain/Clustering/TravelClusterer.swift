import Foundation

nonisolated struct TravelClusteringConfiguration: Sendable {
    var placeRadiusKilometers = 30.0
    var maximumPlaceGap: TimeInterval = 72 * 60 * 60
    var maximumJourneyGap: TimeInterval = 5 * 24 * 60 * 60
}

nonisolated struct TravelClusterer: Sendable {
    let configuration: TravelClusteringConfiguration

    init(configuration: TravelClusteringConfiguration = .init()) {
        self.configuration = configuration
    }

    func makeIndex(
        records: [PhotoAssetRecord],
        sourcePhotoCount: Int? = nil,
        generatedAt: Date = Date()
    ) -> TravelIndexSnapshot {
        let validRecords = records
            .filter { $0.coordinate.isValid }
            .sorted {
                if $0.creationDate == $1.creationDate { return $0.id < $1.id }
                return $0.creationDate < $1.creationDate
            }

        let placeGroups = groupIntoPlaces(validRecords)
        let places = placeGroups.enumerated().map(makePlace)
        let journeys = groupIntoJourneys(places)
        let indexedPhotos = zip(placeGroups, places).flatMap { records, place in
            records.map { record in
                var indexed = record
                indexed.placeID = place.id
                return indexed
            }
        }

        return TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: generatedAt,
                sourcePhotoCount: sourcePhotoCount ?? records.count,
                locatedPhotoCount: validRecords.count,
                places: places,
                journeys: journeys
            ),
            photos: indexedPhotos
        )
    }

    private func groupIntoPlaces(_ records: [PhotoAssetRecord]) -> [[PhotoAssetRecord]] {
        guard let first = records.first else { return [] }
        var result: [[PhotoAssetRecord]] = []
        var current = [first]
        var center = SphericalCenterAccumulator(coordinate: first.coordinate)

        for record in records.dropFirst() {
            let previousDate = current.last?.creationDate ?? record.creationDate
            let timeGap = record.creationDate.timeIntervalSince(previousDate)
            let distance = GlobeMath.distanceKilometers(
                from: center.coordinate,
                to: record.coordinate
            )

            if timeGap <= configuration.maximumPlaceGap,
               distance <= configuration.placeRadiusKilometers {
                current.append(record)
                center.append(record.coordinate)
            } else {
                result.append(current)
                current = [record]
                center = SphericalCenterAccumulator(coordinate: record.coordinate)
            }
        }
        result.append(current)
        return result
    }

    private func makePlace(offset: Int, records: [PhotoAssetRecord]) -> TravelPlace {
        let center = records[0].coordinate
        let cover = records.max { lhs, rhs in
            coverScore(lhs) < coverScore(rhs)
        }
        let idSeed = records.map(\.id).min() ?? "\(offset)"

        return TravelPlace(
            id: "place-\(stableHash(idSeed))",
            name: "",
            country: nil,
            coordinate: center,
            startDate: records.first?.creationDate ?? .distantPast,
            endDate: records.last?.creationDate ?? .distantPast,
            photoCount: records.count,
            coverAssetID: cover?.id
        )
    }

    private func groupIntoJourneys(_ places: [TravelPlace]) -> [TravelJourney] {
        guard let first = places.first else { return [] }
        var groups = [[first]]

        for place in places.dropFirst() {
            let previousEnd = groups.last?.last?.endDate ?? place.startDate
            if place.startDate.timeIntervalSince(previousEnd) <= configuration.maximumJourneyGap {
                groups[groups.count - 1].append(place)
            } else {
                groups.append([place])
            }
        }

        return groups.map { group in
            return TravelJourney(
                id: "journey-\(stableHash(group[0].id))",
                title: "",
                startDate: group[0].startDate,
                endDate: group.last?.endDate ?? group[0].endDate,
                placeIDs: group.map(\.id)
            )
        }
    }

    private func coverScore(_ record: PhotoAssetRecord) -> Int64 {
        let orientationBonus: Int64 = record.pixelWidth >= record.pixelHeight ? 2_000_000_000 : 0
        let favoriteBonus: Int64 = record.isFavorite ? 4_000_000_000 : 0
        let resolution = Int64(record.pixelWidth) * Int64(record.pixelHeight)
        return favoriteBonus + orientationBonus + min(resolution, 1_999_999_999)
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private struct SphericalCenterAccumulator {
        private var x: Double
        private var y: Double
        private var z: Double

        init(coordinate: GeoCoordinate) {
            let vector = Self.vector(for: coordinate)
            x = vector.x
            y = vector.y
            z = vector.z
        }

        var coordinate: GeoCoordinate {
            let horizontal = sqrt(x * x + y * y)
            return GeoCoordinate(
                latitude: atan2(z, horizontal) * 180 / .pi,
                longitude: atan2(y, x) * 180 / .pi
            )
        }

        mutating func append(_ coordinate: GeoCoordinate) {
            let vector = Self.vector(for: coordinate)
            x += vector.x
            y += vector.y
            z += vector.z
        }

        private static func vector(for coordinate: GeoCoordinate) -> (
            x: Double,
            y: Double,
            z: Double
        ) {
            let latitude = coordinate.latitude * .pi / 180
            let longitude = coordinate.longitude * .pi / 180
            return (
                cos(latitude) * cos(longitude),
                cos(latitude) * sin(longitude),
                sin(latitude)
            )
        }
    }
}
