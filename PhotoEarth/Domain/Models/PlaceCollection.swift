import Foundation

/// LensPin applies this threshold to each visit after indexing located items.
nonisolated enum JourneyVisitThreshold {
    static let storageKey = "photoEarth.minimumJourneyItems"
    static let defaultValue = 5
    static let range = 1...1_000
    static let presets = [1, 3, 5, 10, 20, 50]

    static func normalized(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    static func load(from defaults: UserDefaults = .standard) -> Int {
        normalized(defaults.object(forKey: storageKey) as? Int ?? defaultValue)
    }

    static func includes(_ visit: TravelPlace, minimum: Int) -> Bool {
        minimum <= 1 || visit.photoCount >= minimum
    }
}

/// A recent-visit shelf section follows the user's calendar month. Visits
/// that span two months belong to the month of their last photo, while the
/// card still shows the complete visit range.
nonisolated struct RecentVisitMonth: Identifiable, Hashable, Sendable {
    let startDate: Date
    let endDate: Date
    var visits: [PlaceCollection]

    var id: Date { startDate }
}

/// A collection contains only place summaries. Photo records stay in SQLite.
nonisolated struct PlaceCollection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let places: [TravelPlace]
    enum Scope: Hashable, Sendable {
        case visits
        case country(String)
        case city(country: String, name: String)
    }
    var scope: Scope = .visits
    var countryJourneyCoverAssetID: String?
    var usesCountryJourneyCover: Bool {
        if case let .country(key) = scope { return key != "unresolved" }
        return false
    }
    var groupsPhotosByJourney = false
    var journeyDates: ClosedRange<Date>?

    private static let flagRegions = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.utf8.count == 2 })

    private var countryFlag: String? {
        guard case let .country(key) = scope, key.hasPrefix("region:") else { return nil }
        let code = String(key.dropFirst("region:".count))
        guard Self.flagRegions.contains(code) else { return nil }

        let regionalIndicatorA: UInt32 = 0x1F1E6
        return code.unicodeScalars.map { letter in
            String(UnicodeScalar(regionalIndicatorA + letter.value - 65)!)
        }.joined()
    }

    var titleWithCountryFlag: String {
        countryFlag.map { "\($0) \(title)" } ?? title
    }

    var journeyDateText: String? {
        journeyDates.map { AppLocalization.dateRange(from: $0.lowerBound, to: $0.upperBound) }
    }

    func journeySegments(in journeys: [TravelJourney]) -> [PlaceCollection] {
        EarthSlideshowSegment.scoped(to: places, journeys: journeys).map { segment in
            PlaceCollection(id: "city-trip:\(segment.visits[0].id)", title: title, subtitle: subtitle,
                            places: Self.sorted(segment.visits), journeyDates: segment.startDate...segment.endDate)
        }
    }

    /// Resolve semantic country/city membership in the same SQLite read version
    /// used by every page. A reused visit ID at a new coordinate is not the
    /// place the user selected; it must not silently enter this collection.
    func matchingPlaceIDs(in snapshot: [TravelPlace]) throws -> [String] {
        switch scope {
        case let .country(country):
            return snapshot.filter { Self.countryKey($0) == country }.map(\.id)
        case let .city(country, name):
            return snapshot.filter {
                Self.normalized($0.country) == country && Self.normalized($0.name) == name
                    && PlaceDisplayLabel(place: $0).hasCity
            }.map(\.id)
        case .visits:
            let source = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
            guard places.allSatisfy({ source[$0.id]?.coordinate == $0.coordinate }) else {
                throw PhotoWallSelectionError.changedCollection
            }
            return placeIDs
        }
    }

    var placeIDs: [String] { places.map(\.id) }
    var photoCount: Int { places.reduce(0) { $0 + $1.photoCount } }
    var latestPlace: TravelPlace? { places.first }
    var representsSingleCity: Bool {
        switch scope {
        case .country:
            return false
        case .city:
            return true
        case .visits:
            guard let first = places.first else { return false }
            guard PlaceDisplayLabel(place: first).isComplete else { return places.count == 1 }
            let country = Self.countryKey(first)
            let city = Self.cityKey(first)
            return places.allSatisfy {
                PlaceDisplayLabel(place: $0).isComplete
                    && Self.countryKey($0) == country
                    && Self.cityKey($0) == city
            }
        }
    }

    static func recent(_ places: [TravelPlace], minimumVisitItems: Int = 1) -> [PlaceCollection] {
        sorted(places.filter { JourneyVisitThreshold.includes($0, minimum: minimumVisitItems) }).map { place in
            let label = PlaceDisplayLabel(place: place)
            return PlaceCollection(id: place.id, title: label.displayCity,
                                   subtitle: label.displaySubtitle, places: [place])
        }
    }

    /// The input is already in recent-visit order. Preserve that stable card
    /// order while adding calendar-month headings to the loaded prefix.
    static func recentMonths(
        inRecencyOrder visits: [PlaceCollection],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [RecentVisitMonth] {
        var result: [RecentVisitMonth] = []
        for visit in visits {
            guard let date = visit.latestPlace?.endDate else { continue }
            let startOfDay = calendar.startOfDay(for: date)
            let interval = calendar.dateInterval(of: .month, for: date)
            let monthComponents = calendar.dateComponents([.era, .year, .month], from: date)
            let startDate = interval?.start ?? calendar.date(from: monthComponents) ?? startOfDay
            let nextStart = interval?.end
                ?? calendar.date(byAdding: .month, value: 1, to: startDate)
                ?? startOfDay.addingTimeInterval(86_400)
            let endDate = calendar.date(byAdding: .day, value: -1, to: nextStart)
                ?? nextStart.addingTimeInterval(-1)

            if result.last?.startDate == startDate {
                result[result.count - 1].visits.append(visit)
            } else {
                result.append(RecentVisitMonth(startDate: startDate, endDate: endDate, visits: [visit]))
            }
        }
        return result
    }

    /// The home shelves present destinations rather than every time-separated
    /// visit. Keep the newest visit as the card and let `city(containing:in:)`
    /// expand it back to every matching visit when the user opens the city.
    /// Unresolved places stay independent so fallback labels never hide photos.
    static let homeRecentLimit = 5

    static func homeCityRepresentatives(_ places: [TravelPlace], minimumVisitItems: Int = 1) -> [TravelPlace] {
        homeCityRepresentatives(inRecencyOrder: sorted(places), minimumVisitItems: minimumVisitItems)
    }

    /// The overview freezes its ordering while it is active. This variant lets
    /// labels collapse duplicate cards without a metadata refresh reordering
    /// the shelf under the current focus.
    static func homeCityRepresentatives(inRecencyOrder places: [TravelPlace], minimumVisitItems: Int = 1) -> [TravelPlace] {
        var seen = Set<CityIdentity>()
        return places.filter { place in
            guard JourneyVisitThreshold.includes(place, minimum: minimumVisitItems) else { return false }
            let label = PlaceDisplayLabel(place: place)
            guard label.isComplete else { return true }
            return seen.insert(cityIdentity(for: place)).inserted
        }
    }

    static func countries(_ places: [TravelPlace], journeys: [TravelJourney] = [],
                          excluding excluded: Set<String> = []) -> [PlaceCollection] {
        var journeyByVisit: [String: String] = [:]
        for journey in journeys {
            for id in journey.placeIDs where journeyByVisit[id] == nil {
                journeyByVisit[id] = journey.id
            }
        }
        return Dictionary(grouping: places, by: countryKey)
            .map { countryKey, members in
                let ordered = sorted(members)
                let cityCount = Set(ordered.lazy.filter { PlaceDisplayLabel(place: $0).isComplete }.map { cityKey($0) }).count
                let country = ordered.lazy.compactMap { PlaceDisplayLabel(place: $0).displayCountry }.first
                let cover = countryKey == "unresolved" ? nil
                    : latestJourneyCover(in: ordered, journeyByVisit: journeyByVisit, excluding: excluded)
                return PlaceCollection(id: countryKey == "unresolved" ? "country:unresolved" : "country:\(countryKey)",
                                       title: countryKey == "unresolved"
                                           ? AppLocalization.unresolvedPlace
                                           : (country ?? AppLocalization.unresolvedPlace),
                                       subtitle: countryKey == "unresolved" ? AppLocalization.placeCount(ordered.count) : AppLocalization.cityCount(cityCount),
                                       places: ordered, scope: .country(countryKey), countryJourneyCoverAssetID: cover)
            }
            .sorted {
                // Unresolved places remain accessible without disguising them as a country.
                if $0.id == "country:unresolved" { return false }
                if $1.id == "country:unresolved" { return true }
                return Self.collectionComesFirstByRecency($0, $1)
            }
    }

    private static func latestJourneyCover(in ordered: [TravelPlace], journeyByVisit: [String: String],
                                          excluding excluded: Set<String>) -> String? {
        guard let latest = ordered.first else { return nil }
        // A visit without indexed journey membership forms a trip of its own.
        let trip: EarthSlideshowSegment
        if let id = journeyByVisit[latest.id] {
            trip = EarthSlideshowSegment(id: id, visits: ordered.filter { journeyByVisit[$0.id] == id })
        } else {
            trip = EarthSlideshowSegment(id: "visit:" + latest.id, visits: [latest])
        }
        return trip.coverAssetID(excluding: excluded)
    }

    /// Home cards represent a city even when several time-separated visits
    /// produced different place IDs. Pin those IDs now so the subsequent wall
    /// cannot silently admit nearby cities from the map viewport.
    static func city(containing selected: TravelPlace, in places: [TravelPlace]) -> PlaceCollection {
        let selectedLabel = PlaceDisplayLabel(place: selected)
        let members: [TravelPlace]
        if selectedLabel.isComplete {
            let selectedCountry = countryKey(selected)
            let selectedCity = cityKey(selected)
            members = places.filter {
                PlaceDisplayLabel(place: $0).isComplete
                    && countryKey($0) == selectedCountry
                    && cityKey($0) == selectedCity
            }
        } else {
            members = places.filter { $0.id == selected.id && $0.coordinate == selected.coordinate }
        }
        let ordered = sorted(members.isEmpty ? [selected] : members)
        let label = PlaceDisplayLabel(place: ordered[0])
        return PlaceCollection(
            id: "home-city:\(ordered.map(\.id).joined(separator: ","))",
            title: label.displayCity,
            subtitle: label.displaySubtitle,
            places: ordered,
            scope: .visits
        )
    }

    var cities: [PlaceCollection] {
        let candidates = id == "country:unresolved" ? places : places.filter { PlaceDisplayLabel(place: $0).isComplete }
        return Dictionary(grouping: candidates, by: Self.cityKey).map { _, members in
            let ordered = Self.sorted(members)
            let label = PlaceDisplayLabel(place: ordered[0])
            return PlaceCollection(id: "\(id)/city:\(ordered.map(\.id).joined(separator: ","))", title: label.displayCity,
                                   subtitle: label.displaySubtitle, places: ordered, groupsPhotosByJourney: true)
        }.sorted(by: Self.collectionComesFirstByRecency)
    }

    private static func cityKey(_ place: TravelPlace) -> String {
        // Anonymous clusters must never be merged just because they share a fallback label.
        let name = place.offlinePlaceID ?? normalized(place.name)
        return PlaceDisplayLabel(place: place).isComplete ? name : "unresolved:\(place.id)"
    }

    static func countryKey(_ place: TravelPlace) -> String {
        let label = PlaceDisplayLabel(place: place)
        guard label.isComplete || (!normalized(place.regionCode).isEmpty && label.displayCountry != nil) else {
            return "unresolved"
        }
        if let code = JourneyRegionNames.identifier(code: normalized(place.regionCode), fallback: normalized(place.country)) {
            // Preserve the routes used by snapshots published before these two territories had keys.
            switch code {
            case "NE:SOL": return "name:Somaliland"
            case "NE:CYN": return "name:Northern Cyprus"
            default: return "region:\(code)"
            }
        }
        let country = normalized(place.country)
        return country.isEmpty ? "unresolved" : "name:\(country)"
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sorted(_ places: [TravelPlace]) -> [TravelPlace] {
        places.sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate > $1.endDate }
    }

    private static func collectionComesFirstByRecency(
        _ lhs: PlaceCollection,
        _ rhs: PlaceCollection
    ) -> Bool {
        let lhsDate = lhs.latestPlace?.endDate ?? .distantPast
        let rhsDate = rhs.latestPlace?.endDate ?? .distantPast
        return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
    }

    enum CityIdentity: Hashable, Sendable {
        case catalog(String)
        case named(country: String, city: String)
        case unresolvedVisit(String)
    }

    static func cityIdentity(for visit: TravelPlace) -> CityIdentity {
        if let id = visit.offlinePlaceID { return .catalog(id) }
        guard PlaceDisplayLabel(place: visit).isComplete else { return .unresolvedVisit(visit.id) }
        return .named(country: countryKey(visit), city: cityKey(visit))
    }
}
