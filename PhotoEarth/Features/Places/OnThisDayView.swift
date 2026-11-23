import SwiftUI

struct OnThisDayView: View {
    @ObservedObject var model: AppModel
    let isActive: Bool
    @Binding var detail: AnniversaryDetailSelection?
    let requestAccess: (AnniversaryAccessRequest) -> Void
    let controlGlobe: @MainActor @Sendable (EarthSlideshowCameraTarget, Bool) -> Void
    let restoreGlobe: () -> Void

    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date.now
    @State private var chosen: DateComponents?
    @State private var browser: AnniversaryBrowser?
    @State private var loadedQuery: Query?
    @State private var failed = false
    @State private var attempt = 0
    @State private var picker = false
    @State private var show: EarthSlideshowCoordinator?
    @State private var showReturnFocus: Target?
    @State private var lastDetail: AnniversaryDetailSelection?
    @State private var restoration: Target?
    @Namespace private var shelfFocus
    @Environment(\.resetFocus) private var resetFocus
    @FocusState private var focus: Target?

    private enum Target: Hashable {
        case date, previous, next, play, expand(Int), photo(Int, String)
        var year: Int? {
            switch self {
            case .expand(let y), .photo(let y, _): y
            default: nil
            }
        }
    }
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .autoupdatingCurrent
        return cal
    }
    private var date: Date {
        let md = chosen ?? calendar.dateComponents([.month, .day], from: now)
        return calendar.anniversaryDate(month: md.month!, day: md.day!)!
    }
    private var title: String { date.formatted(.dateTime.month(.wide).day().locale(AppLocalization.locale)) }
    private var years: [Int] {
        let year = calendar.component(.year, from: now)
        return AnniversaryDay.years(from: model.index?.places.map(\.year).min(), through: year)
    }
    private struct Query: Hashable {
        let date: Date
        let currentYear: Int
        let zone: String
        let revision: String?
        let excluded: Set<String>
        let active: Bool
        let attempt: Int
    }
    private var query: Query {
        Query(date: date, currentYear: calendar.component(.year, from: now), zone: calendar.timeZone.identifier,
              revision: model.index?.contentRevision, excluded: model.excludedAssetIDs, active: isActive, attempt: attempt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            header.padding(.horizontal, FullScreenMapLayout.contentHorizontalInset)
            if failed {
                Button(String(localized: "common.retry")) { attempt += 1 }
                    .frame(maxWidth: .infinity)
            } else if let browser {
                shelves(browser)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(reduceTransparency ? 1 : 0.64))
        .opacity(show == nil ? 1 : 0)
        .sheet(isPresented: $picker) {
            AnniversaryDatePicker(date: date, calendar: calendar, years: years, browser: browser, model: model) { selection in
                chosen = selection.map { calendar.dateComponents([.month, .day], from: $0) }
                picker = false
                focus = .date
            }
        }
        .fullScreenCover(item: $show, onDismiss: { restoreGlobe(); focus = showReturnFocus ?? .play }) { coordinator in
            EarthSlideshowView(coordinator: coordinator, anniversaryPlaces: model.indexedPlaces) { coordinator.cancel(); show = nil }
                .presentationBackground(.clear)
        }
        .onChange(of: detail?.id) { _, new in
            if new == nil, let selection = lastDetail, selection.browser === browser {
                restoration = .photo(selection.browser.shelves[selection.index].id, selection.record.id)
            }
            lastDetail = detail
        }
        .onChange(of: purchases.access) { old, new in
            if old.permitsLibrary && !new.permitsLibrary && !model.isUsingSampleData {
                clearContent()
                attempt += 1
            }
        }
        .onChange(of: isActive) { _, active in if active { now = .now } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = .now }
        .onChange(of: query) { _, next in
            if let loadedQuery, loadedQuery != next { clearContent() }
        }
        .task(id: query) {
            let requested = query
            guard browser == nil || loadedQuery != requested else { return }
            clearContent()
            failed = false
            guard isActive else { return }
            do {
                let reader = try await model.makePhotoReadSnapshot()
                let md = calendar.dateComponents([.month, .day], from: date)
                let rows = years.map { year in
                    let interval = calendar.anniversaryDate(month: md.month!, day: md.day!, year: year)
                        .flatMap { calendar.dateInterval(of: .day, for: $0) }
                    return AnniversaryShelf(id: year, range: interval.map { $0.start..<$0.end }, nextOffset: 0)
                }
                let session = AnniversaryBrowser(model: model, reader: reader, shelves: rows)
                for i in rows.indices { try await session.load(i, preview: true) }
                try Task.checkCancellation()
                loadedQuery = requested
                browser = session
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private func clearContent() {
        show?.cancel()
        show = nil
        detail = nil
        lastDetail = nil
        restoration = nil
        loadedQuery = nil
        browser = nil
    }

    private var header: some View {
        HStack(spacing: 20) {
            arrow(-1)
            Button { picker = true } label: {
                HStack(spacing: 16) {
                    Text(title).font(.system(size: 46, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 22, weight: .semibold))
                }
            }
            .focused($focus, equals: .date)
            .accessibilityIdentifier("anniversary-date")
            arrow(1)
            Spacer()
            EarthSlideshowEntryButton(title: String(localized: "anniversary.play"), minimumHeight: 82, action: startShow)
                .focused($focus, equals: .play)
                .disabled(browser?.shelves.contains { !$0.records.isEmpty } != true)
                .accessibilityIdentifier("anniversary-play")
        }
        .buttonStyle(.glass)
    }

    private func arrow(_ step: Int) -> some View {
        Button {
            guard let next = calendar.date(byAdding: .day, value: step, to: date) else { return }
            chosen = calendar.dateComponents([.month, .day], from: next)
        } label: { Image(systemName: step < 0 ? "chevron.left" : "chevron.right") }
        .focused($focus, equals: step < 0 ? .previous : .next)
        .accessibilityLabel(step < 0 ? String(localized: "anniversary.previous") : String(localized: "anniversary.next"))
        .accessibilityIdentifier(step < 0 ? "anniversary-previous" : "anniversary-next")
    }

    private func shelves(_ session: AnniversaryBrowser) -> some View {
        GeometryReader { geo in
            let inset = FullScreenMapLayout.contentHorizontalInset
            let width = floor((geo.size.width - inset * 2 - 180 - 108 - 64) / 5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(session.shelves.indices, id: \.self) { i in
                            shelf(session, index: i, width: max(64, width))
                        }
                    }
                    .padding(.horizontal, inset)
                    .padding(.vertical, 12)
                }
                .focusScope(shelfFocus)
                .task(id: restoration) {
                    guard let restoration, case .photo(_, let id) = restoration else { return }
                    proxy.scrollTo(id, anchor: nil)
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    resetFocus(in: shelfFocus)
                    focus = restoration
                }
                .onExitCommand(perform: focus?.year == nil ? nil : {
                    proxy.scrollTo("anniversary-top", anchor: .top)
                    focus = .date
                })
            }
        }
        .onPlayPauseCommand { startShow() }
    }

    private func shelf(_ session: AnniversaryBrowser, index: Int, width: CGFloat) -> some View {
        let row = session.shelves[index]
        let empty = row.records.isEmpty
        let current = row.id == (focus?.year ?? session.shelves.first(where: { !$0.records.isEmpty })?.id)
        let count = row.expanded ? row.records.count : min(5, row.records.count)
        return HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 14) {
                Rectangle().frame(width: current ? 32 : 16, height: 2)
                Text(verbatim: String(row.id))
                    .font(.system(size: current ? 39 : 31, weight: current ? .semibold : .medium))
            }
            .foregroundStyle(Color(white: empty ? 0.53 : current ? 1 : 0.82))
            .frame(width: 180, height: empty ? 76 : 42, alignment: .leading)
            .visualEffect { label, geo in
                let tileHeight = width * 0.67
                let extraRows = max(0, (count - 1) / 5)
                let offset = min(CGFloat(extraRows) * (tileHeight + 16), max(0, -geo.frame(in: .scrollView).minY))
                return label.offset(y: row.expanded ? offset : 0)
            }
            .accessibilityIdentifier("anniversary-year-\(row.id)")
            if empty {
                Text(String(localized: "anniversary.no_record"))
                    .font(.system(size: 25)).foregroundStyle(.secondary)
                    .frame(height: 76)
                    .accessibilityIdentifier("anniversary-empty")
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    let locations = row.locationLabels(in: model.indexedPlaces)
                    Text(locationTitle(locations))
                        .font(.system(size: 31, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("anniversary-locations-\(row.id)")
                    HStack(alignment: .top, spacing: 0) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 16), count: 5),
                                  alignment: .leading, spacing: 16) {
                            ForEach(row.records.prefix(count)) { record in
                                ViewportPhotoCell(record: record, dateText: record.creationDate.formatted(.dateTime.hour().minute()),
                                                  placeName: nil, isFocused: focus == .photo(row.id, record.id),
                                                  isActive: isActive && detail == nil && show == nil, isMosaic: true,
                                                  width: width, height: width * 0.67) { image in
                                    authorize(session, ranges: [row.range].compactMap { $0 }) {
                                        restoration = nil
                                        detail = AnniversaryDetailSelection(browser: session, index: index, record: record, preview: image)
                                    }
                                }
                                .id(record.id)
                                .prefersDefaultFocus(restoration == .photo(row.id, record.id), in: shelfFocus)
                                .focused($focus, equals: .photo(row.id, record.id))
                                .task(id: row.expanded && record.id == row.records.last?.id && !row.failed) {
                                    if row.expanded, record.id == row.records.last?.id, !row.failed { try? await session.load(index) }
                                }
                            }
                        }
                        .frame(width: width * 5 + 64, alignment: .leading)
                        Spacer(minLength: 12)
                        if row.failed {
                            Button(String(localized: "common.retry")) { Task { try? await session.load(index) } }
                        } else if row.records.count > 5 || row.nextOffset != nil {
                            Button {
                                if row.expanded { session.shelves[index].expanded = false }
                                else {
                                    authorize(session, ranges: [row.range].compactMap { $0 }) { session.shelves[index].expanded = true }
                                }
                            } label: { Image(systemName: row.expanded ? "chevron.up" : "chevron.down") }
                            .buttonStyle(.glass)
                            .focused($focus, equals: .expand(row.id))
                            .accessibilityLabel(row.expanded ? String(localized: "wall.journey.collapse") : String(localized: "wall.journey.expand"))
                            .accessibilityIdentifier("anniversary-expand-\(row.id)")
                            .frame(height: width * 0.67)
                        }
                    }
                }
            }
        }
        .padding(.vertical, empty ? 4 : 16)
        .background(alignment: .leading) { Rectangle().fill(.white.opacity(0.22)).frame(width: 1) }
        .focusSection()
        .id(index == 0 ? "anniversary-top" : "anniversary-row-\(row.id)")
    }

    private func locationTitle(_ labels: [PlaceDisplayLabel]) -> AttributedString {
        guard !labels.isEmpty else { return AttributedString(AppLocalization.unresolvedPlace) }
        var title = AttributedString()
        for label in labels {
            if !title.characters.isEmpty { title.append(AttributedString("  ·  ")) }
            if label.hasCity { title.append(label.styledName(citySize: 31)) }
            else if let country = label.displayCountry { title.append(AttributedString(country)) }
        }
        return title
    }

    private func authorize(_ session: AnniversaryBrowser, ranges: [Range<Date>], open: @escaping () -> Void) {
        let requested = query
        requestAccess(AnniversaryAccessRequest(title: title, ranges: ranges, reader: session.reader,
                                              isCurrent: { browser === session && query == requested }, open: open))
    }

    private func startShow() {
        guard let browser else { return }
        let ranges = browser.shelves.filter { !$0.records.isEmpty }.compactMap(\.range)
        guard !ranges.isEmpty else { return }
        let origin = focus
        authorize(browser, ranges: ranges) {
            showReturnFocus = origin
            let scope = EarthSlideshowScope(id: "anniversary", title: title, kind: .anniversary)
            let coordinator = EarthSlideshowCoordinator(scope: scope, places: [], analyticsLibrary: model.analyticsLibrary,
                                                        reduceMotion: reduceMotion, makeSnapshot: { try await browser.snapshot() },
                                                        cameraAction: controlGlobe)
            show = coordinator
            coordinator.start(waitingForConfirmation: true)
        }
    }
}
