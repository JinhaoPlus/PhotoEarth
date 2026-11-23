import Foundation

/// Search the frozen journey summaries. Matching a stop selects the entire trip.
nonisolated struct SlideshowJourneyFilter {
    struct Country: Identifiable {
        let id: String
        let name: String
    }

    struct City: Identifiable {
        let id: PlaceCollection.CityIdentity
        let name: String
    }

    private struct Entry {
        let journey: EarthSlideshowSegment
        let years: ClosedRange<Int>
        let cities: Set<PlaceCollection.CityIdentity>
        let countries: Set<String>
        let searchText: String
    }

    private let entries: [Entry]
    let years: [Int]
    let countries: [Country]
    let citiesByCountry: [String: [City]]

    init(_ journeys: [EarthSlideshowSegment], calendar: Calendar = .current) {
        var countryNames: [String: String] = [:]
        var cityNames: [String: [PlaceCollection.CityIdentity: String]] = [:]
        var allYears = Set<Int>()
        entries = journeys.map { journey in
            let start = calendar.component(.year, from: journey.startDate)
            let end = calendar.component(.year, from: journey.endDate)
            let years = min(start, end)...max(start, end)
            allYears.formUnion(years)
            var ids = Set<String>()
            var names = Set<String>()
            var cities = Set<PlaceCollection.CityIdentity>()
            for visit in journey.visits {
                let label = PlaceDisplayLabel(place: visit)
                let key = PlaceCollection.countryKey(visit)
                if let country = label.displayCountry {
                    if key != "unresolved" {
                        countryNames[key] = country
                        ids.insert(key)
                    }
                    names.insert(country)
                }
                if label.hasCity {
                    let id = PlaceCollection.cityIdentity(for: visit)
                    cities.insert(id)
                    cityNames[key, default: [:]][id] = label.displayCity
                    names.insert(label.displayCity)
                }
            }
            return Entry(journey: journey, years: years, cities: cities, countries: ids,
                         searchText: names.joined(separator: " "))
        }
        citiesByCountry = cityNames.mapValues { names in
            names.map { City(id: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        years = allYears.sorted(by: >)
        countries = countryNames.map { Country(id: $0.key, name: $0.value) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func matches(year: Int?, country: String?, city: PlaceCollection.CityIdentity? = nil, query: String) -> [EarthSlideshowSegment] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.compactMap { entry in
            if let year, !entry.years.contains(year) { return nil }
            if let country, !entry.countries.contains(country) { return nil }
            if let city, !entry.cities.contains(city) { return nil }
            guard terms.allSatisfy(entry.searchText.localizedStandardContains) else { return nil }
            return entry.journey
        }
    }
}
