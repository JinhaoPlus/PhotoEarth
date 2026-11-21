import Foundation

/// The wall owns membership. A slideshow stores only the frozen identity and
/// title of that scope; it never expands into a neighboring city or country.
nonisolated struct EarthSlideshowScope: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case library
        case recentVisit
        case city
        case country
        case currentView
        case collection
    }

    let id: String
    let title: String
    let kind: Kind
}

nonisolated enum EarthSlideshowTransitionKind: String, Hashable, Sendable {
    case dissolve
    /// A time-directed dissolve with only a few points of visual drift. It is
    /// deliberately not a full-frame slide transition.
    case directional
    /// A dissolve with a restrained pull-back to reconcile different framing.
    case settle
    /// A slower dissolve carrying a quiet date imprint over the photographs.
    case dateReveal
}

nonisolated struct EarthSlideshowTransition: Hashable, Sendable {
    let kind: EarthSlideshowTransitionKind
    let duration: TimeInterval
}

nonisolated struct EarthSlideshowItem: Identifiable, Hashable, Sendable {
    let record: PhotoAssetRecord
    let transition: EarthSlideshowTransition

    var id: String { record.id }
}

nonisolated struct EarthSlideshowChapter: Identifiable, Hashable, Sendable {
    let visit: TravelPlace

    var id: String { visit.offlinePlaceID ?? visit.id }
}

nonisolated struct EarthSlideshowConfiguration: Hashable, Sendable {
    var similarityLongEdge = 384
    var maximumVideoDuration: TimeInterval = 12
    var stillDuration: TimeInterval = 3.6
    var livePhotoDuration: TimeInterval = 3.8
    var dynamicEndHold: TimeInterval = 0.18
    var chapterTitleDuration: TimeInterval = 1.2
    var earthIntroDuration: TimeInterval = 3.4
    var earthBridgeDuration: TimeInterval = 2.8
    var earthEndingDuration: TimeInterval = 3.4

    static let standard = EarthSlideshowConfiguration()
}

nonisolated struct PhotoSimilarityConfiguration: Hashable, Sendable {
    /// Revision 2 is kept explicit so a future Vision revision cannot silently
    /// change a user's selection for otherwise identical input.
    var visionRevision = 2
    var nearDuplicateDistance: Float = 0.10
    var relatedSceneDistance: Float = 0.20
    var relatedTimeWindow: TimeInterval = 10 * 60
    var relatedDistanceMeters: Double = 500
    var metadataFallbackTimeWindow: TimeInterval = 2
    var metadataFallbackDistanceMeters: Double = 8

    static let standard = PhotoSimilarityConfiguration()
}

nonisolated enum EarthSlideshowPhase: Equatable, Sendable {
    case idle
    case preparing
    case earthIntro
    case chapterTitle
    case presentingItem
    case transitioningItem
    case earthChapterBridge
    case ending
    case completed
    case failed(String)
    case cancelled

    var keepsDisplayAwake: Bool {
        switch self {
        case .preparing, .earthIntro, .chapterTitle, .presentingItem, .transitioningItem, .earthChapterBridge, .ending:
            true
        case .idle, .completed, .failed, .cancelled:
            false
        }
    }

}

nonisolated struct EarthSlideshowPreparationProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case reading
        case analyzing
        case ready
    }

    var stage: Stage = .reading
    var analyzedCount = 0
    var candidateCount = 0
    var readyCount = 0
}

nonisolated enum EarthSlideshowCameraTarget: Sendable {
    case chapter(TravelPlace, isOpening: Bool)
    case ending(TravelPlace)
}

nonisolated enum EarthSlideshowPlanError: LocalizedError, Equatable, Sendable {
    case empty
    case unavailable

    var errorDescription: String? {
        switch self {
        case .empty:
            AppLocalization.string(
                "slideshow.error.empty",
                defaultValue: "No playable memories are available in this photo wall."
            )
        case .unavailable:
            AppLocalization.string(
                "slideshow.error.unavailable",
                defaultValue: "This slideshow could not be prepared. Try again."
            )
        }
    }
}
