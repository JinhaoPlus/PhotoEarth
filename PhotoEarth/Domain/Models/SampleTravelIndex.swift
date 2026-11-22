import Foundation

enum SampleTravelIndex {
#if DEBUG
    /// Two fictional trips, including a return to Tokyo within the newer trip.
    /// Distinct stock frames identify the stops in end-to-end playback tests.
    static func makeSlideshowJourneyFixture() -> TravelIndexSnapshot {
        let tokyo = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)
        let kyoto = GeoCoordinate(latitude: 35.0116, longitude: 135.7681)
        let osaka = GeoCoordinate(latitude: 34.6937, longitude: 135.5023)
        let calendar = Calendar(identifier: .gregorian)
        let stops = [
            ("tokyo-arrival", "Tokyo", tokyo, 2025, 4, 2, "sample-tokyo"),
            ("kyoto", "Kyoto", kyoto, 2025, 4, 5, "sample-paris"),
            ("tokyo-return", "Tokyo", tokyo, 2025, 4, 8, "sample-rio"),
            ("osaka", "Osaka", osaka, 2023, 11, 3, "sample-istanbul"),
            ("tokyo-older", "Tokyo", tokyo, 2023, 11, 6, "sample-sydney"),
        ]
        var places: [TravelPlace] = []
        var photos: [PhotoAssetRecord] = []
        for (id, city, coordinate, year, month, day, image) in stops {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            let label = try? JourneyPlaceCatalog.shared.label(coordinate, locale: AppLocalization.locale)
            let count = JourneyVisitThreshold.defaultValue
            for ordinal in 1...count {
                let assetID = "\(image)-\(ordinal)"
                let size = SamplePhotoResource.pixelDimensions(for: assetID)
                photos.append(PhotoAssetRecord(id: assetID, coordinate: coordinate,
                    creationDate: date.addingTimeInterval(Double(ordinal)), pixelWidth: size?.width ?? 1600,
                    pixelHeight: size?.height ?? 1000, isFavorite: false, placeID: id))
            }
            places.append(TravelPlace(id: id, name: label?.city ?? city, country: label?.country ?? "Japan",
                regionCode: "JP", offlinePlaceID: city, coordinate: coordinate, startDate: date,
                endDate: date.addingTimeInterval(Double(count)), photoCount: count, coverAssetID: "\(image)-1"))
        }
        let journeys = [Array(places.prefix(3)), Array(places.suffix(2))].map { visits in
            TravelJourney(id: "sample-trip-\(visits[0].id)", title: "", startDate: visits[0].startDate,
                          endDate: visits[visits.count - 1].endDate, placeIDs: visits.map(\.id))
        }
        return TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
            generatedAt: places[2].endDate, sourcePhotoCount: photos.count, locatedPhotoCount: photos.count,
            places: places, journeys: journeys), photos: photos)
    }

    /// Fictional coordinates/dates and credited stock images for map-review UI tests.
    static func makeMapReviewFixture() -> TravelIndexSnapshot {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let points = [GeoCoordinate(latitude: 48.85837, longitude: 2.29448),
                      GeoCoordinate(latitude: 48.86061, longitude: 2.33764),
                      GeoCoordinate(latitude: 48.87379, longitude: 2.29504)]
        let photos = (1...125).map { ordinal in
            PhotoAssetRecord(id: "sample-paris-\(ordinal)",
                             coordinate: points[ordinal <= 120 ? 0 : (ordinal <= 124 ? 1 : 2)],
                             creationDate: date.addingTimeInterval(-Double(ordinal)),
                             pixelWidth: 1600, pixelHeight: 1132, isFavorite: false, placeID: "sample-map-review")
        }
        let label = try? JourneyPlaceCatalog.shared.label(points[0], locale: AppLocalization.locale)
        let place = TravelPlace(id: "sample-map-review", name: label?.city ?? "", country: label?.country, regionCode: label?.regionCode,
                                coordinate: points[0], startDate: photos.last!.creationDate, endDate: photos.first!.creationDate,
                                photoCount: photos.count, coverAssetID: photos.first?.id)
        return TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: date,
                                                     sourcePhotoCount: photos.count, locatedPhotoCount: photos.count,
                                                     places: [place], journeys: []), photos: photos)
    }

    /// A sparse month layout that verifies native tvOS focus enters a short
    /// intervening row instead of skipping to the next matching column.
    static func makeRecentFocusFixture() -> TravelIndexSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let specifications: [(id: String, name: String, year: Int, month: Int, day: Int)] = [
            ("sample-focus-march-first", "March First", 2025, 3, 20),
            ("sample-focus-march-second", "March Second", 2025, 3, 10),
            ("sample-focus-february-only", "February Only", 2025, 2, 15),
            ("sample-focus-january-first", "January First", 2025, 1, 20),
            ("sample-focus-january-second", "January Second", 2025, 1, 10),
        ]
        var places: [TravelPlace] = []
        var photos: [PhotoAssetRecord] = []
        for (offset, specification) in specifications.enumerated() {
            let date = calendar.date(from: DateComponents(
                year: specification.year,
                month: specification.month,
                day: specification.day
            )) ?? Date(timeIntervalSince1970: 0)
            let coordinate = GeoCoordinate(latitude: 30, longitude: Double(offset))
            let assetID = "\(specification.id)-photo"
            for ordinal in 0..<JourneyVisitThreshold.defaultValue {
                photos.append(PhotoAssetRecord(
                    id: ordinal == 0 ? assetID : "\(assetID)-\(ordinal)",
                    coordinate: coordinate,
                    creationDate: date,
                    pixelWidth: 1_600,
                    pixelHeight: 1_000,
                    isFavorite: false,
                    placeID: specification.id
                ))
            }
            places.append(TravelPlace(
                id: specification.id,
                name: specification.name,
                country: "Focus Fixture",
                coordinate: coordinate,
                startDate: date,
                endDate: date,
                photoCount: JourneyVisitThreshold.defaultValue,
                coverAssetID: assetID
            ))
        }
        return TravelIndexSnapshot(
            index: TravelIndex(
                schemaVersion: TravelIndex.currentSchemaVersion,
                generatedAt: Date(timeIntervalSince1970: 1_741_000_000),
                sourcePhotoCount: photos.count,
                locatedPhotoCount: photos.count,
                places: places,
                journeys: []
            ),
            photos: photos
        )
    }

    /// Public stock images with fictional metadata. Never substitutes live IDs.
    static func makeOverviewStress() -> TravelIndexSnapshot {
        let base = make()
        var places: [TravelPlace] = []
        var photos: [PhotoAssetRecord] = []
        for number in 0..<1_000 {
            let template = base.index.places[number % base.index.places.count]
            let placeID = "sample-shelf-\(number)"
            let date = Date(timeIntervalSince1970: 1_750_000_000 - Double(number) * 86_400)
            for ordinal in 1...50 {
                let assetID = "\(template.id)-\(number * 50 + ordinal)"
                let dimensions = SamplePhotoResource.pixelDimensions(for: assetID)
                photos.append(PhotoAssetRecord(id: assetID, coordinate: template.coordinate,
                    creationDate: date.addingTimeInterval(Double(ordinal)), pixelWidth: dimensions?.width ?? 1_600, pixelHeight: dimensions?.height ?? 1_000,
                    isFavorite: false, placeID: placeID))
            }
            // Keep every stress-test destination semantically unique. The real
            // home now collapses repeated visits to the same city.
            places.append(TravelPlace(id: placeID, name: "\(template.name) \(number + 1)", country: template.country, regionCode: template.regionCode,
                coordinate: template.coordinate, startDate: date, endDate: date.addingTimeInterval(50), photoCount: 50,
                coverAssetID: photos.last?.id))
        }
        return TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion,
            generatedAt: Date(timeIntervalSince1970: 1_750_000_100), sourcePhotoCount: photos.count,
            locatedPhotoCount: photos.count, places: places, journeys: []), photos: photos)
    }

    static func makeRatioFixture() -> TravelIndexSnapshot {
        var places: [TravelPlace] = []
        var photos: [PhotoAssetRecord] = []
        let includesPlaybackSamples = ProcessInfo.processInfo.arguments.contains("--playback-control-fixture")
        let patterns = [("landscape", 1_200, 800), ("portrait", 800, 1_200), ("panorama", 2_400, 800)]
        for number in 0..<30 {
            let id = "sample-ratio-place-\(number)"
            let coordinate = GeoCoordinate(latitude: 30, longitude: Double(number))
            let date = Date(timeIntervalSince1970: 1_750_000_000 - Double(number) * 86_400)
            for ordinal in 1...60 {
                let pattern = patterns[(number + ordinal) % patterns.count]
                let mediaKind: PhotoMediaKind = if includesPlaybackSamples, number == 0, ordinal == 60 || ordinal == 58 {
                    .livePhoto
                } else if includesPlaybackSamples, number == 0, ordinal == 59 {
                    .video
                } else {
                    .photo
                }
                photos.append(PhotoAssetRecord(id: "sample-ratio-\(pattern.0)-\(number * 60 + ordinal)", coordinate: coordinate,
                    creationDate: date.addingTimeInterval(Double(ordinal)), pixelWidth: pattern.1, pixelHeight: pattern.2,
                    isFavorite: false, mediaKind: mediaKind, duration: mediaKind == .video ? 18 : 0, placeID: id))
            }
            places.append(TravelPlace(
                id: id,
                name: AppLocalization.format("sample.layout_number", defaultValue: "Layout %@", AppLocalization.number(number + 1)),
                country: AppLocalization.string("sample.layout_country", defaultValue: "Layout Sample"),
                coordinate: coordinate,
                startDate: date, endDate: date.addingTimeInterval(60), photoCount: 60, coverAssetID: photos.last?.id))
        }
        return TravelIndexSnapshot(index: TravelIndex(schemaVersion: TravelIndex.currentSchemaVersion, generatedAt: Date(),
            sourcePhotoCount: photos.count, locatedPhotoCount: photos.count, places: places, journeys: []), photos: photos)
    }
#endif
    static func make() -> TravelIndexSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()

        func date(year: Int, month: Int, day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? now
        }

        func place(
            id: String,
            coordinate: GeoCoordinate,
            startDate: Date,
            endDate: Date,
            photoCount: Int
        ) -> TravelPlace {
            let label = try? JourneyPlaceCatalog.shared.label(coordinate, locale: AppLocalization.locale)
            return TravelPlace(
                id: id,
                name: label?.city ?? "",
                country: label?.country,
                regionCode: label?.regionCode,
                coordinate: coordinate,
                startDate: startDate,
                endDate: endDate,
                photoCount: photoCount,
                coverAssetID: "\(id)-1"
            )
        }

        let places = [
            place(id: "sample-reykjavik", coordinate: GeoCoordinate(latitude: 64.1466, longitude: -21.9426), startDate: date(year: 2025, month: 2, day: 8), endDate: date(year: 2025, month: 2, day: 14), photoCount: 9),
            place(id: "sample-rio", coordinate: GeoCoordinate(latitude: -22.9068, longitude: -43.1729), startDate: date(year: 2024, month: 10, day: 2), endDate: date(year: 2024, month: 10, day: 7), photoCount: 12),
            place(id: "sample-singapore", coordinate: GeoCoordinate(latitude: 1.3521, longitude: 103.8198), startDate: date(year: 2024, month: 5, day: 16), endDate: date(year: 2024, month: 5, day: 20), photoCount: 16),
            place(id: "sample-tokyo", coordinate: GeoCoordinate(latitude: 35.6762, longitude: 139.6503), startDate: date(year: 2023, month: 11, day: 3), endDate: date(year: 2023, month: 11, day: 9), photoCount: 11),
            place(id: "sample-sydney", coordinate: GeoCoordinate(latitude: -33.8688, longitude: 151.2093), startDate: date(year: 2023, month: 1, day: 20), endDate: date(year: 2023, month: 1, day: 27), photoCount: 14),
            place(id: "sample-cape-town", coordinate: GeoCoordinate(latitude: -33.9249, longitude: 18.4241), startDate: date(year: 2022, month: 9, day: 12), endDate: date(year: 2022, month: 9, day: 18), photoCount: 10),
            place(id: "sample-istanbul", coordinate: GeoCoordinate(latitude: 41.0082, longitude: 28.9784), startDate: date(year: 2022, month: 3, day: 5), endDate: date(year: 2022, month: 3, day: 11), photoCount: 8),
            place(id: "sample-paris", coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522), startDate: date(year: 2021, month: 10, day: 18), endDate: date(year: 2021, month: 10, day: 24), photoCount: 13),
            place(id: "sample-new-york", coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060), startDate: date(year: 2021, month: 5, day: 8), endDate: date(year: 2021, month: 5, day: 15), photoCount: 15),
            place(id: "sample-banff", coordinate: GeoCoordinate(latitude: 51.1784, longitude: -115.5708), startDate: date(year: 2020, month: 1, day: 14), endDate: date(year: 2020, month: 1, day: 20), photoCount: 7),
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
                let assetID = "\(place.id)-\(number)"
                let dimensions = SamplePhotoResource.pixelDimensions(for: assetID)
                return PhotoAssetRecord(
                    id: assetID,
                    coordinate: GeoCoordinate(
                        latitude: place.coordinate.latitude + Double((offset % 3) - 1) * 0.08,
                        longitude: place.coordinate.longitude + Double((offset % 5) - 2) * 0.1
                    ),
                    creationDate: place.startDate.addingTimeInterval(Double(offset) * 3_600),
                    pixelWidth: dimensions?.width ?? 1_600,
                    pixelHeight: dimensions?.height ?? 1_067,
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
