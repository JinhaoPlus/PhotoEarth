nonisolated enum ViewportPhotoWallContentState {
    case photos
    case loading
    case failed
    case continuation
    case empty

    static func resolve(recordCount: Int, isLoading: Bool, hasMore: Bool, hasError: Bool) -> Self {
        if recordCount > 0 { return .photos }
        if isLoading { return .loading }
        if hasError { return .failed }
        return hasMore ? .continuation : .empty
    }
}
