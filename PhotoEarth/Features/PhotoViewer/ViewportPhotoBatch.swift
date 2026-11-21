import Foundation

struct ViewportPhotoBatch {
    var clusters: [MapReviewCluster]
    var preview: [PhotoAssetRecord]
    var count: Int { clusters.reduce(0) { $0 + $1.count } }
}

extension AppModel {
    /// Stream the actual pinned spatial query in stable newest-first order.
    /// Both map hosts use exactly the same projection and cluster anchors.
    func viewportPhotoBatch(in snapshot: PhotoViewportSnapshot, grid: MapReviewGrid,
                            reader: SQLiteTravelIndexStore?, placeIDs: Set<String>? = nil,
                            onPreview: ([PhotoAssetRecord]) -> Void = { _ in },
                            isCurrent: () -> Bool) async throws -> ViewportPhotoBatch {
        let countingReader: SQLiteTravelIndexStore?
        if let reader { countingReader = reader } else { countingReader = try await makePhotoReadSnapshot() }
        let operation = UUID()
        var accumulator = MapReviewClusterAccumulator(grid: grid)
        var preview: [PhotoAssetRecord] = []
        var sentPreview = false
        var offset = 0
        var slice = ContinuousClock.now
        do {
            while true {
                try Task.checkCancellation()
                guard isCurrent(), snapshot.isCurrent() else { throw CancellationError() }
                let batch = try await mapReviewViewportCandidates(in: snapshot, offset: offset, reader: countingReader, operationID: operation, placeIDs: placeIDs)
                for photo in batch.records {
                    if slice.duration(to: .now) >= .milliseconds(3) {
                        await Task.yield()
                        slice = .now
                        try Task.checkCancellation()
                        guard isCurrent(), snapshot.isCurrent() else { throw CancellationError() }
                    }
                    guard !excludedAssetIDs.contains(photo.id), snapshot.containsForPhotoWall(photo.coordinate) else { continue }
                    accumulator.insert(photo)
                    if preview.count < 48 { preview.append(photo) }
                }
                guard let next = batch.nextOffset else { break }
                if !sentPreview, !preview.isEmpty {
                    try Task.checkCancellation()
                    guard isCurrent(), snapshot.isCurrent() else { throw CancellationError() }
                    sentPreview = true
                    onPreview(preview)
                }
                guard next > offset else { throw PhotoWallSelectionError.unavailableViewport }
                offset = next
            }
        } catch {
            await countingReader?.finishPhotoWallCounting(operationID: operation)
            throw error
        }
        await countingReader?.finishPhotoWallCounting(operationID: operation)
        try Task.checkCancellation()
        guard isCurrent(), snapshot.isCurrent() else { throw CancellationError() }
        return ViewportPhotoBatch(clusters: accumulator.clusters.values.sorted { $0.cell < $1.cell }, preview: preview)
    }
}
