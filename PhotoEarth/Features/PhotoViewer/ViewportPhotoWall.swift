import SwiftUI
import UIKit

struct ViewportPhotoWall: View {
    let records: [PhotoAssetRecord]
    let isLoading: Bool
    let hasMore: Bool
    let placeLabel: (String) -> PlaceDisplayLabel?
    let selectPhoto: (PhotoAssetRecord, UIImage?) -> Void
    let loadMore: () -> Void
    let close: () -> Void
    var isActive = true
    @Binding var selectedPhotoID: String?
    var errorMessage: String?
    var title = AppLocalization.string("wall.viewport.title", defaultValue: "Memories in This View")
    var canRetry = true
    var emptyHint: String? = AppLocalization.string("wall.viewport.empty_message", defaultValue: "Return to the globe, turn toward a glowing place, or widen the view.")
    var totalPhotoCount: Int?
    var countErrorMessage: String?
    var retryPhotoCount: (() -> Void)?
    var showsPhotoPlaceNames = true
    var startSlideshow: (() -> Void)?
    var openMapReview: (() -> Void)?
    var canOpenMapReview = true

    var labelStates: [String: PlaceLabelLoadState] = [:]
    var resolvePlaceLabels: ([String]) async -> Void = { _ in }
    var onInteraction: () -> Void = {}

    private var labelPlaceIDs: [String] {
        guard isActive, showsPhotoPlaceNames else { return [] }
        let row = focusedPhotoID.flatMap { rowPositions[$0] } ?? 0
        let nearby = rows.dropFirst(max(0, row - 1)).prefix(4).flatMap(\.items).compactMap { record(for: $0.id) }
        let focus = focusedPhotoID.flatMap { record(for: $0) }
        var seen = Set<String>()
        return Array(([focus].compactMap { $0 } + nearby).compactMap(\.placeID).filter { seen.insert($0).inserted }.prefix(15))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedPhotoID: String?
    @FocusState private var isContinuationFocused: Bool
    @FocusState private var isStatusFocused: Bool
    @State private var layout = PhotoRowLayout.Accumulator()
    @State private var dateTexts: [String] = []

    private func record(for id: String) -> PhotoAssetRecord? {
        guard let position = layout.itemPositions[id], records.indices.contains(position),
              records[position].id == id else { return nil }
        return records[position]
    }
    @State private var layoutWidth: Double = 0
    @State private var preparedCount = 0
    @State private var lastPreparedID: String?
    @State private var restorationTargetID: String?
    @State private var isRestoringFocus = true
    @State private var restorationGeneration = UUID()
    @State private var visibleRowIDs: Set<String> = []
    @State private var isBelowPageTop = false
    @State private var isReturningToTop = false
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    private var rows: [PhotoRowLayout.Row] { layout.rows }
    private var rowPositions: [String: Int] { layout.rowPositions }
    private var topReturnPhotoID: String? { isBelowPageTop ? rows.first?.id : nil }
    private var usesStatusFocus: Bool { records.isEmpty && (isLoading || !hasMore) }

    var body: some View {
        GeometryReader { geometry in
            wall(width: geometry.size.width - 2 * FullScreenMapLayout.contentHorizontalInset)
        }
    }

    private func wall(width: CGFloat) -> some View {
        let back: (() -> Void)? = isActive ? { handleBack() } : nil
        return VStack(spacing: 0) {
            header
                .padding(.horizontal, 80)
                .padding(.top, 60)
                .padding(.bottom, 26)

            scrollingWall(width: width)
        }
        .background(wallBackdrop)
        .onChange(of: focusedPhotoID) { _, id in photoFocusChanged(to: id) }
        .task(id: labelPlaceIDs) {
            let ids = labelPlaceIDs
            guard !ids.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await resolvePlaceLabels(ids)
        }
        .onExitCommand(perform: back)
        .onPlayPauseCommand {
            guard isActive, slideshowAvailable else { return }
            startSlideshow?()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewport-photo-wall")
        .accessibilityHidden(!isActive)
    }

    private var wallBackdrop: some View {
        ZStack {
            Color(red: 0.008, green: 0.018, blue: 0.032)
                .opacity(reduceTransparency ? 1 : 0.58)
            LinearGradient(
                colors: [
                    .black.opacity(reduceTransparency ? 0 : 0.38),
                    .clear,
                    .black.opacity(reduceTransparency ? 0 : 0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func scrollingWall(width: Double) -> some View {
        ScrollView {
            if contentState == .empty {
                emptyState
            } else if contentState == .continuation {
                Text(AppLocalization.string("wall.keep_searching", defaultValue: "No photos found yet."))
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 100)
            } else {
                photoRows
            }
            paginationFooter.disabled(isReturningToTop)
        }
        // Keep focused rows and their shadows inside the scrolling
        // region so they can never paint over the fixed heading.
        .scrollClipDisabled(false)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 1
        } action: { _, belowTop in
            isBelowPageTop = belowTop
            if !belowTop, isReturningToTop, let firstRow = rows.first {
                focusRestoredRowIfVisible(firstRow.id)
            }
        }
        .onChange(of: isReturningToTop) { _, returning in
            guard returning else { return }
            scrollToTop()
        }
        .onChange(of: isActive) { _, active in
            if active {
                restorationTargetID = selectedPhotoID
                restoreFocus()
            } else {
                isReturningToTop = false
                restorationGeneration = UUID()
                restorationTargetID = selectedPhotoID
                isRestoringFocus = true
                focusedPhotoID = nil
            }
        }
        .onChange(of: records, initial: true) { _, _ in updateRows(width: width) }
        .onChange(of: width) { _, width in updateRows(width: width) }
        .onChange(of: rows.first?.id) { _, firstID in
            if firstID == nil { isReturningToTop = false }
            restoreFocus()
        }
        .onChange(of: isLoading) { _, loading in
            if !loading, records.isEmpty { restoreFocus() }
        }
        .onAppear { restoreFocus() }
    }

    private var photoRows: some View {
        LazyVStack(alignment: .leading, spacing: 36) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 36) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { position, item in
                        if let photo = record(for: item.id), let index = layout.itemPositions[item.id], dateTexts.indices.contains(index) {
                            photoButton(photo, dateText: dateTexts[index], width: row.widths[position], height: row.height)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep the leading clearance in the first scroll target.
                // Native Focus may align this target while restoring a page.
                .padding(.top, row.id == rows.first?.id ? 12 : 0)
                .id(row.id)
                .focusSection()
                .onAppear {
                    visibleRowIDs.insert(row.id)
                    focusRestoredRowIfVisible(row.id)
                }
                .onDisappear { visibleRowIDs.remove(row.id) }
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, FullScreenMapLayout.contentHorizontalInset)
        .padding(.bottom, 38)
        .focusSection()
    }

    @ViewBuilder private var paginationFooter: some View {
        if isLoading {
            ProgressView(AppLocalization.string("wall.loading", defaultValue: "Unfolding memories…"))
                .font(.system(size: 23))
                .tint(.cyan)
                .padding(.vertical, 40)
        } else if let errorMessage {
            VStack(spacing: 22) {
                Text(errorMessage).font(.system(size: 26))
                if canRetry {
                    Button(AppLocalization.string("common.retry", defaultValue: "Try Again"), action: loadMore)
                        .buttonStyle(.glass)
                        .focused($isContinuationFocused)
                        .accessibilityIdentifier("photo-wall-retry")
                }
            }
            .padding(.vertical, 60)
        } else if hasMore {
            // A sentinel outside the lazy rows appears even offscreen.
            // Load on near-end focus, with an explicit fallback button.
            Button(records.isEmpty
                ? AppLocalization.string("wall.find_more", defaultValue: "Keep Finding Photos")
                : AppLocalization.string("wall.show_more", defaultValue: "Unfold More Memories"), action: loadMore)
                .font(.system(size: 26, weight: .medium))
                .buttonStyle(.glass)
                .padding(.bottom, 60)
                .focused($isContinuationFocused)
                .accessibilityIdentifier("photo-wall-load-more")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 42, weight: .semibold))
                    .accessibilityIdentifier("photo-wall-title")
                if contentState != .empty || (totalPhotoCount ?? 0) > 0 || countErrorMessage != nil {
                    Text(statusText)
                        .accessibilityIdentifier("photo-wall-count")
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .focusable(isActive && usesStatusFocus)
            .focusEffectDisabled()
            .focused($isStatusFocused)
            Spacer()
            if countErrorMessage != nil, let retryPhotoCount {
                Button(action: retryPhotoCount) {
                    Label(AppLocalization.string("wall.count.retry", defaultValue: "Recount Photos"), systemImage: "arrow.clockwise")
                        .font(.system(size: 23, weight: .medium))
                        .padding(.horizontal, 12).frame(minHeight: 66)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("photo-wall-retry-count")
            }
            if let openMapReview {
                Button(action: openMapReview) {
                    Label(AppLocalization.string("review.title", defaultValue: "Map Review"), systemImage: "map")
                        .font(.system(size: 23, weight: .medium))
                        .padding(.horizontal, 12).frame(minHeight: 66)
                }
                .buttonStyle(.glass)
                .disabled(!canOpenMapReview)
                .accessibilityIdentifier("photo-wall-map-review")
            }
            if startSlideshow != nil {
                Button {
                    startSlideshow?()
                } label: {
                    Label(
                        AppLocalization.string("slideshow.start", defaultValue: "Earth Slideshow"),
                        systemImage: "play.rectangle.fill"
                    )
                    .font(.system(size: 23, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 66)
                }
                .buttonStyle(.glassProminent)
                .tint(.cyan.opacity(0.72))
                .disabled(!slideshowAvailable)
                .accessibilityIdentifier("photo-wall-slideshow")

            }
        }
        // Treat the fixed header as one destination spanning the content
        // width, so an Up press from any first-row photo can enter its native
        // controls even though the visible buttons are right-aligned.
        .focusSection()
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60, weight: .ultraLight))
                .foregroundStyle(.cyan)
            Text(AppLocalization.string("wall.empty_title", defaultValue: "No Photos"))
                .font(.system(size: 34, weight: .medium))
            if let emptyHint {
                Text(emptyHint)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 160)
    }

    private var contentState: ViewportPhotoWallContentState {
        .resolve(recordCount: records.count, isLoading: isLoading, hasMore: hasMore, hasError: errorMessage != nil)
    }

    private var slideshowAvailable: Bool {
        // The wall needs at least one concrete record to freeze visit
        // membership. Keep the visible entry disabled during the first read
        // instead of accepting a press that cannot create a session yet.
        startSlideshow != nil && totalPhotoCount != 0 && !records.isEmpty
    }

    private func photoButton(_ record: PhotoAssetRecord, dateText: String, width: Double, height: Double) -> some View {
        ViewportPhotoCell(record: record, dateText: dateText,
                                 placeName: showsPhotoPlaceNames ? placeName(for: record) : nil,
                          isFocused: focusedPhotoID == record.id, isActive: isActive, width: width, height: height) { preview in
            selectedPhotoID = record.id
            selectPhoto(record, preview)
        }
        .focused($focusedPhotoID, equals: record.id)
        .disabled(isRestoringFocus && restorationTargetID != nil && record.id != restorationTargetID)
    }

    private func placeName(for record: PhotoAssetRecord) -> String {
        guard let placeID = record.placeID else { return AppLocalization.string("photo.travel_memory", defaultValue: "Travel Memory") }
        let label = placeLabel(placeID)
        if let label, label.hasCity { return label.displayCity }
        if labelStates[placeID] == .loading {
            return AppLocalization.string("place.loading", defaultValue: "Finding place…")
        }
        return label?.displayCity ?? AppLocalization.unknownPlace(near: nil)
    }

    private var statusText: String {
        if let countErrorMessage { return countErrorMessage }
        if let totalPhotoCount { return AppLocalization.photoCount(totalPhotoCount) }
        return AppLocalization.string("wall.counting_all", defaultValue: "Counting all photos…")
    }

    private func handleBack() {
        guard let firstID = topReturnPhotoID else {
            close()
            return
        }
        // At the top Back can exit even if native Focus hasn't sent its
        // final change callback. While still scrolling, finish the same jump.
        guard !isReturningToTop else { return }
        restorationTargetID = firstID
        restorationGeneration = UUID()
        isRestoringFocus = true
        isReturningToTop = true
        focusedPhotoID = nil
    }

    private func photoFocusChanged(to id: String?) {
        guard isActive, let id else { return }
        // Native Focus can propose the old row while the target is offscreen.
        guard !isRestoringFocus || id == restorationTargetID else { return }
        if isReturningToTop {
            guard !isBelowPageTop else { return }
            isReturningToTop = false
        }
        isRestoringFocus = false
        onInteraction()
        selectedPhotoID = id
        if errorMessage == nil, let index = layout.itemPositions[id], index >= records.count - 12 {
            loadMore()
        }
    }

    private func restoreFocus() {
        guard isActive else { return }
        guard let target = (restorationTargetID ?? selectedPhotoID).flatMap({ record(for: $0)?.id }) ?? records.first?.id else {
            if errorMessage != nil && canRetry || contentState == .continuation {
                isContinuationFocused = true
            } else if usesStatusFocus {
                isStatusFocused = true
            }
            return
        }
        restorationTargetID = target
        isRestoringFocus = true
        restorationGeneration = UUID()
        let generation = restorationGeneration
        Task { @MainActor in
            await Task.yield()
            guard isActive, restorationGeneration == generation else { return }
            scrollToRestorationTarget()
            // Scroll first. A new lazy row takes focus from its onAppear;
            // already-visible rows use the same deferred handoff here.
            if let row = rowPositions[target], rows.indices.contains(row) {
                focusRestoredRowIfVisible(rows[row].id)
            }
        }
    }

    private func scrollToRestorationTarget() {
        guard let target = restorationTargetID,
              let row = rowPositions[target], rows.indices.contains(row) else { return }
        if row == 0 {
            scrollToTop()
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(id: rows[row].id, anchor: .center)
        }
    }

    private func scrollToTop() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(edge: .top) }
    }

    private func focusRestoredRowIfVisible(_ rowID: String) {
        guard isActive, isRestoringFocus, visibleRowIDs.contains(rowID),
              !isReturningToTop || !isBelowPageTop,
              let target = restorationTargetID, let row = rowPositions[target],
              rows.indices.contains(row), rows[row].id == rowID else { return }
        let generation = restorationGeneration
        Task { @MainActor in
            await Task.yield()
            guard isActive, isRestoringFocus, restorationGeneration == generation,
                  !isReturningToTop || !isBelowPageTop,
                  visibleRowIDs.contains(rowID), restorationTargetID == target else { return }
            if focusedPhotoID == target {
                photoFocusChanged(to: target)
            } else {
                focusedPhotoID = target
            }
        }
    }

    private func updateRows(width: Double) {
        guard width > 0 else { return }
        let isAppend = abs(layoutWidth - width) < 1 && records.count > preparedCount &&
            (preparedCount == 0 || records[preparedCount - 1].id == lastPreparedID)
        if !isAppend {
            // Width changes, edits and removals can alter an existing row.
            // Normal page appends leave all previous geometry untouched.
            layout = PhotoRowLayout.Accumulator()
            dateTexts = []
            preparedCount = 0
        }
        let appended = records.dropFirst(preparedCount)
        let items = appended.map { PhotoRowLayout.Item(id: $0.id, aspectRatio: PhotoPreviewMetadata($0).aspectRatio) }
        dateTexts.append(contentsOf: appended.map { AppLocalization.shortDate($0.creationDate) })
        layout.append(items, width: width, spacing: 36)
        layoutWidth = width
        preparedCount = records.count
        lastPreparedID = records.last?.id
    }
}

/// Each wall cell hands its already decoded preview to the detail transition.
/// It retains that reference only while the cell is onscreen.
private struct ViewportPhotoCell: View {
    let record: PhotoAssetRecord
    let dateText: String
    let placeName: String?
    let isFocused: Bool
    let isActive: Bool
    let width: Double
    let height: Double
    let selectPhoto: (UIImage?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var preview: UIImage?
    @State private var usesFocusedResolution = false

    var body: some View {
        Button {
            selectPhoto(preview)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                PhotoAssetImage(assetID: record.id, contentMode: .fit,
                                targetSize: PhotoImageSizing.wallTargetSize(pixelWidth: record.pixelWidth,
                                                                          pixelHeight: record.pixelHeight,
                                                                          cardSize: CGSize(width: width, height: height),
                                                                          displayScale: displayScale,
                                                                          isFocused: usesFocusedResolution),
                                isActive: isActive,
                                priority: isFocused ? .focus : .visible,
                                onImageChange: { preview = $0 })
                    .frame(width: width, height: height)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(isFocused ? 0.95 : 0.14), lineWidth: isFocused ? 3 : 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if record.mediaKind.isPlayable {
                            mediaBadge
                            .padding(12)
                        }
                    }
                HStack(alignment: .firstTextBaseline) {
                    if let placeName {
                        Text(placeName)
                            .font(.system(size: 27, weight: .medium))
                            .lineLimit(1)
                    } else {
                        Text(dateText)
                            .font(.system(size: 23))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(isFocused ? 0.85 : 0.65))
                    }
                    Spacer(minLength: 0)
                    if record.isFavorite { Image(systemName: "heart.fill").font(.system(size: 23)).foregroundStyle(.pink) }
                }
                if placeName != nil {
                    Text(dateText)
                        .font(.system(size: 23))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(isFocused ? 0.85 : 0.65))
                }
            }
            .frame(width: width)
            .foregroundStyle(.white)
            .scaleEffect(isFocused && !reduceMotion ? 1.025 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16, y: 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(QuietPhotoButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("viewport-photo-\(record.id)")
        .task(id: isActive && isFocused) {
            guard isActive, isFocused, !usesFocusedResolution else { return }
            // A passing focus can keep using the wall preview. Once upgraded,
            // the cell retains the same size until it leaves the wall's window.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            usesFocusedResolution = true
        }
        .onChange(of: isActive) { _, active in if !active { releasePreview() } }
        .onDisappear { releasePreview() }
    }

    private func releasePreview() {
        preview = nil
        usesFocusedResolution = false
    }

    @ViewBuilder
    private var mediaBadge: some View {
        if record.mediaKind == .livePhoto {
            Image(systemName: "livephoto")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .floatingSurface(in: Circle())
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                Text(videoBadgeText)
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .floatingSurface(in: Capsule())
        }
    }

    private var videoBadgeText: String {
        guard record.duration > 0 else {
            return AppLocalization.string("detail.media_video", defaultValue: "Video")
        }
        return AppLocalization.mediaDuration(record.duration)
    }

    private var accessibilityLabel: String {
        let base = placeName.map {
            AppLocalization.format(
                "wall.photo_accessibility",
                defaultValue: "%1$@, %2$@",
                $0,
                dateText
            )
        } ?? dateText
        guard record.mediaKind.isPlayable else { return base }
        let kind = record.mediaKind == .livePhoto
            ? AppLocalization.string("detail.media_live_photo", defaultValue: "Live Photo")
            : AppLocalization.string("detail.media_video", defaultValue: "Video")
        return AppLocalization.format("wall.photo_accessibility", defaultValue: "%1$@, %2$@", kind, base)
    }

}
