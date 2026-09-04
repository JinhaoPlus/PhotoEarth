import Foundation

enum SampleTravelIndex {
    static func make() -> TravelIndexSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()

        func date(year: Int, month: Int, day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? now
        }

        let places = [
            TravelPlace(
                id: "sample-reykjavik",
                name: "雷克雅未克",
                country: "冰岛",
                coordinate: GeoCoordinate(latitude: 64.1466, longitude: -21.9426),
                startDate: date(year: 2025, month: 2, day: 8),
                endDate: date(year: 2025, month: 2, day: 14),
                photoCount: 9,
                coverAssetID: "sample-reykjavik-1"
            ),
            TravelPlace(
                id: "sample-lisbon",
                name: "里斯本",
                country: "葡萄牙",
                coordinate: GeoCoordinate(latitude: 38.7223, longitude: -9.1393),
                startDate: date(year: 2024, month: 10, day: 2),
                endDate: date(year: 2024, month: 10, day: 7),
                photoCount: 12,
                coverAssetID: "sample-lisbon-1"
            ),
            TravelPlace(
                id: "sample-shanghai",
                name: "上海",
                country: "中国",
                coordinate: GeoCoordinate(latitude: 31.2304, longitude: 121.4737),
                startDate: date(year: 2024, month: 5, day: 16),
                endDate: date(year: 2024, month: 5, day: 20),
                photoCount: 16,
                coverAssetID: "sample-shanghai-1"
            ),
            TravelPlace(
                id: "sample-tokyo",
                name: "东京",
                country: "日本",
                coordinate: GeoCoordinate(latitude: 35.6762, longitude: 139.6503),
                startDate: date(year: 2023, month: 11, day: 3),
                endDate: date(year: 2023, month: 11, day: 9),
                photoCount: 11,
                coverAssetID: "sample-tokyo-1"
            ),
            TravelPlace(
                id: "sample-sydney",
                name: "悉尼",
                country: "澳大利亚",
                coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093),
                startDate: date(year: 2023, month: 1, day: 20),
                endDate: date(year: 2023, month: 1, day: 27),
                photoCount: 14,
                coverAssetID: "sample-sydney-1"
            ),
            TravelPlace(
                id: "sample-cape-town",
                name: "开普敦",
                country: "南非",
                coordinate: GeoCoordinate(latitude: -33.9249, longitude: 18.4241),
                startDate: date(year: 2022, month: 9, day: 12),
                endDate: date(year: 2022, month: 9, day: 18),
                photoCount: 10,
                coverAssetID: "sample-cape-town-1"
            ),
            TravelPlace(
                id: "sample-istanbul",
                name: "伊斯坦布尔",
                country: "土耳其",
                coordinate: GeoCoordinate(latitude: 41.0082, longitude: 28.9784),
                startDate: date(year: 2022, month: 3, day: 5),
                endDate: date(year: 2022, month: 3, day: 11),
                photoCount: 8,
                coverAssetID: "sample-istanbul-1"
            ),
            TravelPlace(
                id: "sample-paris",
                name: "巴黎",
                country: "法国",
                coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522),
                startDate: date(year: 2021, month: 10, day: 18),
                endDate: date(year: 2021, month: 10, day: 24),
                photoCount: 13,
                coverAssetID: "sample-paris-1"
            ),
            TravelPlace(
                id: "sample-new-york",
                name: "纽约",
                country: "美国",
                coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060),
                startDate: date(year: 2021, month: 5, day: 8),
                endDate: date(year: 2021, month: 5, day: 15),
                photoCount: 15,
                coverAssetID: "sample-new-york-1"
            ),
            TravelPlace(
                id: "sample-cusco",
                name: "库斯科",
                country: "秘鲁",
                coordinate: GeoCoordinate(latitude: -13.5319, longitude: -71.9675),
                startDate: date(year: 2020, month: 1, day: 14),
                endDate: date(year: 2020, month: 1, day: 20),
                photoCount: 7,
                coverAssetID: "sample-cusco-1"
            ),
        ]

        let journeys = places.enumerated().map { offset, place in
            TravelJourney(
                id: "sample-journey-\(offset)",
                title: "\(place.year) · \(place.name)",
                startDate: place.startDate,
                endDate: place.endDate,
                placeIDs: [place.id]
            )
        }
        let photos = places.flatMap { place in
            (1...place.photoCount).map { number in
                let offset = number - 1
                return PhotoAssetRecord(
                    id: "\(place.id)-\(number)",
                    coordinate: GeoCoordinate(
                        latitude: place.coordinate.latitude + Double((offset % 3) - 1) * 0.08,
                        longitude: place.coordinate.longitude + Double((offset % 5) - 2) * 0.1
                    ),
                    creationDate: place.startDate.addingTimeInterval(Double(offset) * 3_600),
                    pixelWidth: offset.isMultiple(of: 3) ? 3_000 : 4_000,
                    pixelHeight: offset.isMultiple(of: 3) ? 4_000 : 3_000,
                    isFavorite: offset.isMultiple(of: 7),
                    placeID: place.id
                )
            }
        }

        return TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: now,
                sourcePhotoCount: places.reduce(0) { $0 + $1.photoCount },
                locatedPhotoCount: places.reduce(0) { $0 + $1.photoCount },
                places: places,
                journeys: journeys
            ),
            photos: photos
        )
    }
}
