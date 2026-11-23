import SwiftUI

/// Keeps the memory horizon dense on every TV size without dropping records.
/// Pages are a presentation detail: together their ranges always cover the
/// complete verified preview batch in its original order. A sparse final page
/// may repeat a few preceding frames to preserve the filmstrip's visual rhythm.
nonisolated struct MemoryPhotoStripPaging: Equatable, Sendable {
    static let height: CGFloat = 144
    static let spacing: CGFloat = 6

    static func thumbnailWidth(aspectRatio: CGFloat) -> CGFloat {
        height * min(max(aspectRatio, 0.68), 1.6)
    }

    static func size(for record: PhotoAssetRecord) -> CGSize {
        CGSize(width: thumbnailWidth(aspectRatio: PhotoPreviewMetadata(record).aspectRatio), height: height)
    }

    let pages: [Range<Int>]

    init(widths: [CGFloat], availableWidth: CGFloat) {
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        var ranges: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, tileWidth) in widths.enumerated() {
            if index > start, used + Self.spacing + tileWidth > width {
                ranges.append(start..<index)
                start = index
                used = 0
            }
            used += (index == start ? 0 : Self.spacing) + tileWidth
        }
        if start < widths.count {
            // Give a short last page some context, keeping room for every new photo.
            if let previous = ranges.last {
                let minimumCount = (previous.count + 1) / 2
                while widths.count - start < minimumCount, start > previous.lowerBound + 1,
                      used + Self.spacing + widths[start - 1] <= width {
                    start -= 1
                    used += Self.spacing + widths[start]
                }
            }
            ranges.append(start..<widths.count)
        }
        pages = ranges
    }

    func range(for page: Int) -> Range<Int> {
        guard !pages.isEmpty else { return 0..<0 }
        return pages[min(max(page, 0), pages.count - 1)]
    }
}

struct MemoryPhotoStrip: View {
    let records: [PhotoAssetRecord]
    let isReady: Bool
    let isManipulating: Bool
    let isRefreshing: Bool
    var queryFailed = false
    /// Only supplied by a complete viewport count, never by a page or sample.
    var totalPhotoCount: Int? = nil
    var countIdentifier = "memory-horizon-count"

    var advanceBatch: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0

    private var displayedRecords: [PhotoAssetRecord] {
        isReady && !isManipulating ? records : []
    }

    private struct RotationKey: Equatable {
        let ids: [String]
        let pages: [Range<Int>]
        let hasNextBatch: Bool
    }

    private var countTitle: String {
        if let totalPhotoCount { return AppLocalization.itemCount(totalPhotoCount) }
        return AppLocalization.format("memory_strip.preview_count", defaultValue: "Previews: %@", AppLocalization.number(records.count))
    }

    private var isVerifiedEmpty: Bool { isReady && !isRefreshing && !queryFailed }

    private var emptyStatus: String {
        if queryFailed { return AppLocalization.string("memory_strip.failed", defaultValue: "Previews unavailable") }
        if !isVerifiedEmpty { return AppLocalization.string("memory_strip.searching", defaultValue: "Looking for photos in this view…") }
        if totalPhotoCount == 0 { return AppLocalization.string("memory_strip.empty", defaultValue: "No photos in this view") }
        return AppLocalization.string("memory_strip.no_preview", defaultValue: "No previews available")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if displayedRecords.isEmpty {
                emptyState
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(AppLocalization.string("memory_strip.title", defaultValue: "Photos in this view"))
                        .font(.system(size: 23, weight: .medium))
                        .accessibilityIdentifier("memory-horizon-title")

                    Text(countTitle)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityIdentifier(countIdentifier)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 3, y: 1)

                GeometryReader { proxy in
                    let widths = records.map { MemoryPhotoStripPaging.size(for: $0).width }
                    let paging = MemoryPhotoStripPaging(widths: widths, availableWidth: proxy.size.width)
                    let pageRange = paging.range(for: currentPage)
                    let pageRecords = records[pageRange]
                    ZStack(alignment: .leading) {
                        MemoryPhotoStripPage(records: pageRecords)
                            .id(pageRecords.map(\.id))
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: pageRange)
                    .overlay(alignment: .topTrailing) {
                        if paging.pages.count > 1 {
                            pageProgress(paging: paging)
                                .frame(width: 44)
                                .offset(y: -12)
                                .accessibilityHidden(true)
                        }
                    }
                    .task(id: RotationKey(ids: records.map(\.id), pages: paging.pages, hasNextBatch: advanceBatch != nil)) {
                        currentPage = 0
                        guard paging.pages.count > 1 || advanceBatch != nil else { return }
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(6)) } catch { return }
                            guard !Task.isCancelled else { return }
                            if currentPage + 1 < paging.pages.count {
                                currentPage += 1
                            } else if let advanceBatch {
                                advanceBatch()
                                return
                            } else {
                                currentPage = 0
                            }
                        }
                    }
                }
                .frame(height: MemoryPhotoStripPaging.height)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("memory-horizon-photos")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 80)
        .padding(.top, 16)
        .padding(.bottom, 16)
        // Individual frames carry their own shadow; a screen-wide dark panel
        // would hide the Earth's texture and lower edge at this orbital scale.
        // The map's native legal attribution occupies the clear footer below.
        .padding(.bottom, 88)
        .opacity(isManipulating ? 0 : 1)
        // Old thumbnails disappear in the same update that invalidates a batch.
        // Only a newly verified batch may fade in, never a stale batch fading out.
        .transaction { transaction in
            if !isReady || isManipulating {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory-horizon")
        .accessibilityValue(isReady && !isManipulating
            ? (totalPhotoCount.map { AppLocalization.format("memory_strip.accessibility_ready", defaultValue: "%@ matched in the current view", AppLocalization.itemCount($0)) } ?? countTitle)
            : AppLocalization.string("memory_strip.accessibility_refreshing", defaultValue: "Updating the current view"))
        .accessibilityHidden(isManipulating)
    }

    private func pageProgress(paging: MemoryPhotoStripPaging) -> some View {
        GeometryReader { proxy in
            let pageCount = max(1, paging.pages.count)
            let safePage = min(max(currentPage, 0), pageCount - 1)
            let markerWidth = max(8, proxy.size.width / CGFloat(pageCount))
            let travel = max(0, proxy.size.width - markerWidth)
            let offset = pageCount == 1
                ? 0
                : travel * CGFloat(safePage) / CGFloat(pageCount - 1)

            Capsule()
                .fill(.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.68))
                        .frame(width: markerWidth)
                        .offset(x: offset)
                }
        }
        .frame(height: 3)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            if !isVerifiedEmpty, !queryFailed {
                ProgressView().controlSize(.small).tint(.white.opacity(0.65))
            } else {
                Image(systemName: queryFailed ? "exclamationmark.circle" : "photo")
                    .font(.system(size: 23, weight: .light))
            }
            Text(emptyStatus)
                .font(.system(size: 23, weight: .regular))
                .accessibilityIdentifier(isVerifiedEmpty ? "memory-horizon-empty" : "memory-horizon-status")
        }
        .foregroundStyle(.white.opacity(0.74))
        .shadow(color: .black.opacity(0.65), radius: 7, y: 1)
        .frame(minHeight: 30, alignment: .leading)
    }
}

private struct MemoryPhotoStripPage: View {
    let records: ArraySlice<PhotoAssetRecord>
    @StateObject private var thumbnailStore = MemoryThumbnailStore()

    var body: some View {
        HStack(spacing: MemoryPhotoStripPaging.spacing) {
            ForEach(records) { record in thumbnail(for: record) }
        }
        .task { thumbnailStore.load(records: Array(records)) }
        .onDisappear { thumbnailStore.cancel() }
    }

    @ViewBuilder
    private func thumbnail(for record: PhotoAssetRecord) -> some View {
        let size = MemoryPhotoStripPaging.size(for: record)
        Group {
            if record.id.hasPrefix("sample-") {
                PhotoAssetImage(assetID: record.id, targetSize: CGSize(width: size.width * 2, height: size.height * 2))
            } else if let image = thumbnailStore.images[record.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.055)
                    Image(systemName: "photo")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(.white.opacity(0.24))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if record.mediaKind.isPlayable {
                Image(systemName: record.mediaKind == .livePhoto ? "livephoto" : "video.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .shadow(color: .black.opacity(0.48), radius: 3, y: 2)
    }
}
