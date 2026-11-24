import SwiftUI

extension EarthSlideshowSegment {
    var routeTitle: String {
        var cities: [String] = []
        var previous: PlaceCollection.CityIdentity?
        for visit in visits {
            let city = PlaceCollection.cityIdentity(for: visit)
            if city != previous { cities.append(PlaceDisplayLabel(place: visit).displayCity) }
            previous = city
        }
        return cities.joined(separator: " › ")
    }

    var dateTitle: String { AppLocalization.dateRange(from: startDate, to: endDate) }
}

struct SlideshowJourneyPicker: View {
    @ObservedObject var coordinator: EarthSlideshowCoordinator
    let dismiss: () -> Void
    private enum Section: Hashable {
        case all, year(Int), selected
    }
    private enum Focus: Hashable {
        case section(Section), trip(String), bulk, done
    }
    @State private var draft: Set<String>
    @State private var section: Section
    private struct Location: Hashable {
        var country: String?
        var city: PlaceCollection.CityIdentity?
        var query = ""
    }
    @State private var location = Location()
    @State private var index: SlideshowJourneyFilter?
    @FocusState private var focus: Focus?

    init(coordinator: EarthSlideshowCoordinator, dismiss: @escaping () -> Void) {
        self.coordinator = coordinator
        self.dismiss = dismiss
        let selected = coordinator.selectedJourneyIDs ?? []
        _draft = State(initialValue: selected)
        _section = State(initialValue: selected.isEmpty ? .all : .selected)
    }

    var body: some View {
        Group {
            if let index {
                browser(index)
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 38)
        .frame(width: 1580, height: 840, alignment: .topLeading)
        .task {
            guard index == nil else { return }
            index = await Self.prepareIndex(coordinator.availableJourneys)
        }
        .onChange(of: location) { _, value in
            if value != Location() { coordinator.recordAction(.filterJourneys) }
        }
        .onChange(of: focus) { _, target in
            if case let .section(value) = target { section = value }
        }
        .onExitCommand(perform: dismiss)
    }

    @concurrent private static func prepareIndex(_ journeys: [EarthSlideshowSegment]) async -> SlideshowJourneyFilter {
        SlideshowJourneyFilter(journeys)
    }

    private func browser(_ index: SlideshowJourneyFilter) -> some View {
        let matches: [EarthSlideshowSegment]
        if section == .selected {
            matches = coordinator.availableJourneys.filter { draft.contains($0.id) }
        } else {
            let year: Int? = if case let .year(value) = section { value } else { nil }
            matches = index.matches(year: year, country: location.country, city: location.city, query: location.query)
        }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                Text(Self.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if section != .selected {
                    bulkButton(matches)
                        .focused($focus, equals: .bulk)
                        .onMoveCommand { direction in
                            if direction == .down, let first = matches.first { focus = .trip(first.id) }
                            if direction == .left { focus = .section(section) }
                        }
                } else if coordinator.selectedJourneyIDs != nil {
                    Button(Self.allTrips) { apply(nil) }.accessibilityIdentifier("slideshow-picker-all")
                }
                doneButton.focused($focus, equals: .done)
            }
            .focusSection()
            if section != .selected, coordinator.availableJourneys.count > 4 {
                placeFilters(index)
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            tab(.all, title: Self.allYears, id: "all", firstTrip: matches.first?.id)
                            ForEach(index.years, id: \.self) { value in
                                tab(.year(value), title: String(value), id: String(value), firstTrip: matches.first?.id)
                            }
                        }
                    }
                    Divider()
                    tab(.selected, title: Self.selectionCount(draft.count), id: "selected", firstTrip: matches.first?.id)
                }
                .frame(width: 320)
                .focusSection()
                Divider()
                tripList(matches)
                    .id(section)
                    .id(location)
            }
        }
        .defaultFocus($focus, .section(section), priority: .userInitiated)
        .task {
            await Task.yield()
            focus = .section(section)
        }
    }

    private func tab(_ tab: Section, title: String, id: String, firstTrip: String?) -> some View {
        let target = Focus.section(tab)
        return Button {
            section = tab
            if let firstTrip { focus = .trip(firstTrip) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: tab == .selected ? "checklist" : "calendar").frame(width: 34)
                Text(title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 26, weight: .semibold))
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 16)
            .modifier(SlideshowBrowserRowAppearance(focused: focus == target, highlighted: section == tab))
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: target)
        .accessibilityAddTraits(section == tab ? .isSelected : [])
        .accessibilityIdentifier("slideshow-picker-tab-\(id)")
        .onMoveCommand { direction in
            if direction == .right, let firstTrip { focus = .trip(firstTrip) }
        }
    }

    private func placeFilters(_ index: SlideshowJourneyFilter) -> some View {
        HStack(spacing: 18) {
            if !index.countries.isEmpty { countryMenu(index.countries) }
            if let key = location.country ?? (index.countries.count == 1 ? index.countries.first?.id : nil),
               let cities = index.citiesByCountry[key], !cities.isEmpty {
                cityMenu(cities)
            }
            TextField(AppLocalization.string("slideshow.trip_search", defaultValue: "City, country, or region"), text: $location.query)
                .accessibilityIdentifier("slideshow-picker-search")
            if location != Location() {
                Button {
                    location = Location()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel(AppLocalization.string("slideshow.clear_filters", defaultValue: "Reset Filters"))
                .accessibilityIdentifier("slideshow-picker-reset")
            }
        }
        .focusSection()
    }

    private func countryMenu(_ countries: [SlideshowJourneyFilter.Country]) -> some View {
        let all = AppLocalization.string("slideshow.all_countries", defaultValue: "All Countries and Regions")
        return Menu {
            Button(all) {
                location.country = nil
                location.city = nil
            }
            ForEach(countries) { item in
                Button(item.name) {
                    location.country = item.id
                    location.city = nil
                }
                .accessibilityIdentifier("slideshow-picker-country-\(item.id)")
            }
        } label: {
            Label(countries.first { $0.id == location.country }?.name ?? all, systemImage: "globe")
                .lineLimit(2)
        }
        .accessibilityIdentifier("slideshow-picker-country")
    }

    private func cityMenu(_ cities: [SlideshowJourneyFilter.City]) -> some View {
        let all = AppLocalization.string("slideshow.all_cities", defaultValue: "All Cities")
        return Menu {
            Button(all) {
                location.city = nil
            }
            ForEach(cities) { item in
                Button(item.name) {
                    location.city = item.id
                }
            }
        } label: {
            Label(cities.first { $0.id == location.city }?.name ?? all, systemImage: "building.2").lineLimit(2)
        }
        .accessibilityIdentifier("slideshow-picker-city")
    }

    private func bulkButton(_ matches: [EarthSlideshowSegment]) -> some View {
        let ids = Set(matches.map(\.id))
        let remove = !ids.isEmpty && ids.isSubset(of: draft)
        let title = remove
            ? AppLocalization.format("slideshow.remove_matches", defaultValue: "Deselect %lld trips", Int64(ids.count))
            : AppLocalization.format("slideshow.select_matches", defaultValue: "Select %lld trips", Int64(ids.count))
        return Button(title) {
            coordinator.recordAction(.bulkSelect)
            if remove { draft.subtract(ids) }
            else { draft.formUnion(ids) }
        }
        .disabled(ids.isEmpty)
        .accessibilityIdentifier("slideshow-picker-bulk")
    }

    private var doneButton: some View {
        Button(AppLocalization.string("common.done", defaultValue: "Done")) {
            apply(draft)
        }
        .buttonStyle(.glassProminent)
        .disabled(draft.isEmpty)
        .accessibilityIdentifier("slideshow-picker-done")
    }

    private func tripList(_ visible: [EarthSlideshowSegment]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if visible.isEmpty {
                    Text(section == .selected
                         ? AppLocalization.string("slideshow.no_selected_trips", defaultValue: "No trips selected")
                         : AppLocalization.string("slideshow.no_matching_trips", defaultValue: "No matching trips"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(visible) { journey in row(journey, in: visible) }
            }
            .padding(18)
        }
        .focusSection()
    }

    private func row(_ journey: EarthSlideshowSegment, in visible: [EarthSlideshowSegment]) -> some View {
        let checked = draft.contains(journey.id)
        return Button {
            if checked {
                draft.remove(journey.id)
                if section == .selected, let index = visible.firstIndex(where: { $0.id == journey.id }) {
                    let next = visible.dropFirst(index + 1).first ?? visible.prefix(index).last
                    focus = next.map { .trip($0.id) } ?? .section(.selected)
                }
            } else {
                draft.insert(journey.id)
            }
        } label: {
            HStack(spacing: 24) {
                Rectangle().fill(.quaternary)
                    .frame(width: 128, height: 76)
                    .overlay {
                        if let id = coordinator.coverAssetID(for: journey) {
                            PhotoAssetImage(assetID: id, targetSize: CGSize(width: 256, height: 152), usesOriginalCover: true)
                                .id(id)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(journey.routeTitle).font(.headline).lineLimit(1)
                    Text(journey.dateTitle).font(.caption)
                }
                Spacer()
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
        }
        .focused($focus, equals: .trip(journey.id))
        .onMoveCommand { direction in
            if direction == .left { focus = .section(section) }
            if direction == .up, visible.first?.id == journey.id {
                focus = section == .selected ? .done : .bulk
            }
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityIdentifier("slideshow-picker-trip-\(journey.id)")
    }

    private func apply(_ selection: Set<String>?) {
        coordinator.chooseJourneys(selection)
        dismiss()
    }

    static var title: String { AppLocalization.string("slideshow.choose_trips", defaultValue: "Choose Trips") }
    static var allTrips: String { AppLocalization.string("slideshow.all_trips", defaultValue: "All Trips") }
    private static var allYears: String { AppLocalization.string("slideshow.all_years", defaultValue: "All Years") }
    static func selectionCount(_ count: Int) -> String {
        AppLocalization.format("slideshow.trips_selected", defaultValue: "%lld trips selected", Int64(count))
    }
}
