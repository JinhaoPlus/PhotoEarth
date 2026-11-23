import SwiftUI

struct CityJourneyWallInput {
    let model: AppModel
    let session: CollectionPhotoWallSession
    let focusJourney: (CollectionPhotoWallSession.Journey) -> Void
    let select: (CollectionPhotoWallSession.Journey, PhotoAssetRecord, UIImage?) -> Void
}

struct CityJourneyPhotoRows: View {
    let input: CityJourneyWallInput
    let width: CGFloat
    let mosaic: Bool
    let isActive: Bool
    let openedDetail: () -> Void
    let topRequest: Int
    @Binding var selectedID: String?
    @Binding var belowTop: Bool
    @FocusState private var focus: String?
    @State private var didSetInitialFocus = false

    var body: some View {
        let journeys = input.session.visibleJourneys
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 38) {
                    ForEach(journeys) { journey in
                        JourneyRows(journey: journey, input: input, width: width, mosaic: mosaic,
                                    isActive: isActive, focus: $focus, focusedPhoto: { id in
                                        selectedID = id
                                    }, select: { photo, image in
                                        selectedID = photo.id
                                        openedDetail()
                                        input.select(journey, photo, image)
                                    })
                            .id(journey.id)
                    }
                }
                .padding(.horizontal, FullScreenMapLayout.contentHorizontalInset)
                .padding(.vertical, 16)
                .id("journey-wall-top")
            }
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y + $0.contentInsets.top > 8
            } action: { _, value in belowTop = value }
            .onChange(of: journeys.first?.page.records.first?.id, initial: true) { _, id in
                guard isActive, !didSetInitialFocus, let id else { return }
                didSetInitialFocus = true
                focus = id
            }
            .onChange(of: topRequest) {
                guard let first = journeys.first else { return }
                scroll.scrollTo("journey-wall-top", anchor: .top)
                focus = first.page.records.first?.id ?? first.id
            }
            .task(id: isActive) {
                guard isActive, let selectedID else { return }
                scroll.scrollTo(selectedID, anchor: .center)
                await Task.yield()
                guard !Task.isCancelled else { return }
                focus = selectedID
            }
        }
    }
}

private struct JourneyRows: View {
    typealias Journey = CollectionPhotoWallSession.Journey
    let journey: Journey
    let input: CityJourneyWallInput
    let width: CGFloat
    let mosaic: Bool
    let isActive: Bool
    let focus: FocusState<String?>.Binding
    let focusedPhoto: (String) -> Void
    let select: (PhotoAssetRecord, UIImage?) -> Void
    @State private var layout = PhotoRowLayout.Accumulator()

    private var page: CollectionPhotoWallSession { journey.page }
    private var preview: ArraySlice<PhotoAssetRecord> { page.records.prefix(Journey.previewLimit) }
    private var canExpand: Bool {
        (page.totalPhotoCount ?? page.membership?.photoCount ?? 0) > Journey.previewLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 22) {
                Text(journey.collection.journeyDateText ?? "")
                    .font(.system(size: 31, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("journey-date-" + journey.id)
                if let count = page.totalPhotoCount {
                    Text(AppLocalization.itemCount(count)).font(.system(size: 24)).foregroundStyle(.secondary)
                } else if page.countErrorMessage != nil {
                    Button(AppLocalization.string("wall.count.retry", defaultValue: "Count Again")) {
                        page.refreshCount(app: input.model)
                    }
                }
                Spacer()
                if canExpand {
                    Button {
                        journey.isExpanded.toggle()
                        if journey.isExpanded, page.records.count <= Journey.previewLimit { journey.load(app: input.model) }
                    } label: {
                        Label(journey.isExpanded
                              ? AppLocalization.string("wall.journey.collapse", defaultValue: "Collapse")
                              : AppLocalization.string("wall.journey.expand", defaultValue: "Expand"),
                              systemImage: journey.isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .focused(focus, equals: journey.id)
                    .onChange(of: focus.wrappedValue == journey.id) { _, active in
                        if active { input.focusJourney(journey) }
                    }
                    .accessibilityIdentifier("journey-toggle-" + journey.id)
                }
            }
            .frame(minHeight: 60)
            .focusSection()

            let gap: CGFloat = mosaic ? 8 : 20
            let tileWidth = (width - gap * CGFloat(Journey.previewLimit - 1)) / CGFloat(Journey.previewLimit)
            HStack(spacing: gap) {
                ForEach(preview) { photo in
                    cell(photo, width: tileWidth, height: tileWidth * 0.59)
                }
            }
            .frame(maxWidth: .infinity, minHeight: tileWidth * 0.59, alignment: .leading)
            .focusSection()
            if journey.isExpanded {
                LazyVStack(alignment: .leading, spacing: mosaic ? PhotoRowLayout.mosaicGap : 24) {
                    ForEach(layout.rows) { row in
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(row.items.enumerated()), id: \.element.id) { slot, item in
                                if let index = layout.itemPositions[item.id],
                                   page.records.indices.contains(index + Journey.previewLimit),
                                   page.records[index + Journey.previewLimit].id == item.id {
                                    let frame = row.frames[slot]
                                    cell(page.records[index + Journey.previewLimit], width: frame.width, height: frame.height)
                                        .offset(x: frame.minX, y: frame.minY)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: row.height)
                        .focusSection()
                    }
                }
            }
            if let error = page.pagingError {
                HStack {
                    Text(error)
                    Button(AppLocalization.string("common.retry", defaultValue: "Try Again")) { journey.load(app: input.model) }
                }
            }
        }
        .task(id: page.nextOffset) {
            page.exclude(input.session.excludedAssetIDs.union(input.model.excludedAssetIDs), app: input.model)
            guard page.pagingError == nil else { return }
            if preview.count < Journey.previewLimit {
                journey.load(app: input.model, limit: Journey.previewLimit - preview.count)
            } else if journey.isExpanded, page.records.count == Journey.previewLimit {
                journey.load(app: input.model)
            }
        }
        .onChange(of: preview.count) { _, count in
            if count < Journey.previewLimit, page.pagingError == nil {
                journey.load(app: input.model, limit: Journey.previewLimit - count)
            }
        }
        .onChange(of: page.records, initial: true) { old, new in updateLayout(reset: !new.starts(with: old)) }
        .onChange(of: journey.isExpanded) { updateLayout(reset: true) }
        .onChange(of: width) { updateLayout(reset: true) }
        .onChange(of: mosaic) { updateLayout(reset: true) }
    }

    private func cell(_ photo: PhotoAssetRecord, width: CGFloat, height: CGFloat) -> some View {
        ViewportPhotoCell(record: photo, dateText: AppLocalization.shortDate(photo.creationDate),
                          placeName: nil, isFocused: focus.wrappedValue == photo.id, isActive: isActive,
                          isMosaic: mosaic, width: width, height: height) { image in select(photo, image) }
            .focused(focus, equals: photo.id)
            .id(photo.id)
            .onChange(of: focus.wrappedValue == photo.id) { _, focused in
                guard focused, isActive else { return }
                input.focusJourney(journey)
                focusedPhoto(photo.id)
                guard journey.isExpanded, page.pagingError == nil,
                      page.records.suffix(8).contains(where: { $0.id == photo.id }) else { return }
                journey.load(app: input.model)
            }
    }

    private func updateLayout(reset: Bool = false) {
        if reset { layout = PhotoRowLayout.Accumulator() }
        guard journey.isExpanded else { return }
        let added = page.records.dropFirst(Journey.previewLimit + layout.itemPositions.count)
        guard !added.isEmpty else { return }
        layout.append(added.map { PhotoRowLayout.Item(id: $0.id, aspectRatio: PhotoPreviewMetadata($0).aspectRatio) },
                      width: width, spacing: 24, mosaic: mosaic)
    }
}
