import SwiftUI

struct OnThisDayView: View {
    @ObservedObject var model: AppModel
    let isActive: Bool
    @Binding var selectedDay: AnniversaryDay?

    @State private var now = Date.now
    @State private var days: [AnniversaryDay]?
    @State private var failed = false
    @State private var attempt = 0
    @FocusState private var focus: Date?
    @State private var rememberedDay: Date?
    @State private var belowTop = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }

    private struct Query: Equatable {
        var day: Date
        var revision: String?
        var excluded: Set<String>
        var active: Bool
        var attempt: Int
    }

    var body: some View {
        let query = Query(day: calendar.startOfDay(for: now), revision: model.index?.contentRevision,
                          excluded: model.excludedAssetIDs, active: isActive, attempt: attempt)
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(now.formatted(.dateTime.month(.wide).day().locale(AppLocalization.locale)))
                        .font(.system(size: 50, weight: .medium)).accessibilityAddTraits(.isHeader)
                        .id("anniversary-top")
                    if failed {
                        Text(AppLocalization.string("error.wall.index", defaultValue: "The photo index is temporarily unavailable. Try again."))
                        Button(AppLocalization.string("common.retry", defaultValue: "Try Again")) { attempt += 1 }
                    } else if let days, days.isEmpty {
                        ContentUnavailableView(AppLocalization.string("anniversary.empty", defaultValue: "No travel photos from this day in past years"),
                                               systemImage: "calendar")
                            .focusable().accessibilityIdentifier("anniversary-empty")
                    } else if let days {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30), count: 3), alignment: .leading, spacing: 36) {
                            ForEach(days) { day in
                                Button {
                                    rememberedDay = day.id
                                    selectedDay = day
                                } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Color.clear.aspectRatio(1.8, contentMode: .fit)
                                            .overlay { PhotoAssetImage(assetID: day.cover.id, targetSize: CGSize(width: 640, height: 360)) }
                                            .clipped()
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(day.id.formatted(.dateTime.year().locale(AppLocalization.locale))).font(.title3.bold())
                                            Spacer()
                                            Text(AppLocalization.itemCount(day.count)).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 18).padding(.vertical, 12)
                                    }
                                    .foregroundStyle(.white)
                                    .background(.black.opacity(0.48))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(.white.opacity(focus == day.id ? 0.95 : 0.18), lineWidth: focus == day.id ? 3 : 1)
                                    }
                                }
                                .buttonStyle(QuietPhotoButtonStyle())
                                .focusEffectDisabled()
                                .focused($focus, equals: day.id)
                                .accessibilityIdentifier("anniversary-year-\(calendar.component(.year, from: day.id))")
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FullScreenMapLayout.contentHorizontalInset)
                .padding(.top, 110).padding(.bottom, 60)
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, value in belowTop = value }
            .onExitCommand(perform: belowTop && selectedDay == nil ? {
                scroll.scrollTo("anniversary-top", anchor: .top)
                focus = days?.first?.id
            } : nil)
        }
        .background(.black.opacity(reduceTransparency ? 1 : 0.56))
        .onAppear { now = .now }
        .onChange(of: isActive) { _, active in if active { now = .now } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = .now }
        .onChange(of: query.day) { _, _ in selectedDay = nil }
        .task(id: query) {
            guard isActive else { return }
            failed = false
            do {
                let matches = try await model.anniversaryDays(on: query.day, calendar: calendar)
                try Task.checkCancellation()
                days = matches
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
        .onChange(of: model.excludedAssetIDs) { _, _ in
            days = nil
        }
        .onChange(of: selectedDay) { _, day in
            if day == nil { focus = rememberedDay }
        }
    }
}

struct AnniversaryWall: View {
    @ObservedObject var model: AppModel
    let day: AnniversaryDay
    let controlGlobe: @MainActor @Sendable (EarthSlideshowCameraTarget, Bool) -> Void
    let restoreGlobe: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reader: SQLiteTravelIndexStore?
    @State private var records: [PhotoAssetRecord] = []
    @State private var count: Int?
    @State private var nextOffset: Int? = 0
    @State private var loading = false
    @State private var selectedID: String?
    @State private var selectedPhoto: PhotoAssetRecord?
    @State private var preview: UIImage?
    @State private var errorText: String?
    @State private var pageTask: Task<Void, Never>?
    @State private var show: EarthSlideshowCoordinator?

    private var title: String { AppLocalization.shortDate(day.id) }
    private func label(_ id: String) -> PlaceDisplayLabel? { model.indexedPlaces[id].map(PlaceDisplayLabel.init(place:)) }

    var body: some View {
        ZStack {
            ViewportPhotoWall(records: records, isLoading: loading, hasMore: nextOffset != nil,
                              placeLabel: label, selectPhoto: { photo, image in
                                  selectedID = photo.id
                                  selectedPhoto = photo
                                  preview = image
                              }, loadMore: loadMore, close: close, isActive: selectedPhoto == nil && show == nil,
                              selectedPhotoID: $selectedID, errorMessage: errorText, title: title, emptyHint: nil,
                              totalPhotoCount: count, startSlideshow: startShow, analyticsLibrary: model.analyticsLibrary)
                .disabled(selectedPhoto != nil || show != nil)
                .opacity(show == nil ? 1 : 0)
            if let photo = selectedPhoto {
                PhotoDetailView(record: photo, placeLabel: photo.placeID.flatMap(label), initialImage: preview,
                                records: records, hasMorePhotos: nextOffset != nil, isLoadingMorePhotos: loading,
                                pagingError: errorText, loadMorePhotos: loadMore, selectRecord: { next in
                                    selectedID = next.id
                                    selectedPhoto = next
                                    preview = nil
                                }, locationLibrary: model) { selectedPhoto = nil; preview = nil }
            }
            if let show {
                EarthSlideshowView(coordinator: show) { self.show = nil; restoreGlobe() }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: loadMore)
        .onDisappear { pageTask?.cancel(); show?.cancel(); restoreGlobe() }
    }

    private func loadMore() {
        guard !loading, let offset = nextOffset else { return }
        loading = true
        errorText = nil
        pageTask = Task {
            defer { loading = false }
            do {
                if offset == 0 {
                    if reader == nil { reader = try await model.makePhotoReadSnapshot() }
                    if let reader {
                        count = try await reader.anniversaryDays(in: [day.range], excluding: model.excludedAssetIDs).first?.count ?? 0
                    } else { count = day.count }
                }
                let page = try await model.anniversaryPage(in: day.range, reader: reader, offset: offset, excluding: model.excludedAssetIDs)
                try Task.checkCancellation()
                records.append(contentsOf: page.records)
                nextOffset = page.nextOffset
            } catch {
                guard !Task.isCancelled else { return }
                errorText = AppLocalization.string("error.wall.index", defaultValue: "The photo index is temporarily unavailable. Try again.")
            }
        }
    }

    private func startShow() {
        let scope = EarthSlideshowScope(id: "anniversary", title: title, kind: .collection)
        let visits = (model.index?.places ?? []).filter { $0.startDate < day.range.upperBound && $0.endDate >= day.range.lowerBound }
        let coordinator = EarthSlideshowCoordinator(scope: scope, places: visits, analyticsLibrary: model.analyticsLibrary,
                                                   reduceMotion: reduceMotion, makeSnapshot: {
            let snapshot = try SlideshowSnapshot(places: visits, journeys: model.index?.journeys ?? [])
            var offset: Int? = 0
            let excluded = model.excludedAssetIDs
            while let start = offset {
                try Task.checkCancellation()
                let page = try await model.anniversaryPage(in: day.range, reader: reader, offset: start, excluding: excluded)
                try await snapshot.appendBatch(page.records)
                offset = page.nextOffset
            }
            return snapshot
        }, cameraAction: { target, reducedMotion in controlGlobe(target, reducedMotion) })
        show = coordinator
        coordinator.start(waitingForConfirmation: true)
    }
}
