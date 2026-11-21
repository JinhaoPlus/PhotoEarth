import Foundation

nonisolated enum GlobeScale: Equatable, Sendable {
    case globe, map

    init(distance: Double, requestedDistance: Double? = nil) {
        let boundary = GlobeCameraState.regionalDistance
        // MapKit's round trip at the exact city landing can add nanometres.
        // Only that requested landing gets the camera's sub-decimetre tolerance.
        let atRequestedBoundary = requestedDistance == boundary && abs(distance - boundary) < 0.1
        self = distance <= boundary || atRequestedBoundary ? .map : .globe
    }
}

/// Near-map glows remain until a complete (possibly empty) pin batch is ready.
/// Camera callbacks within the same band preserve a manual map style choice.
struct GlobeScalePresentation: Equatable {
    enum Markers: Equatable {
        case places
        case awaitingPhotos
        // An identical set of cells can merge differently after a camera move.
        case photos(UUID, [MapReviewCluster])
    }

    private(set) var scale = GlobeScale.globe
    private(set) var style = PhotoMapStyle.satellite
    private(set) var markers = Markers.places

    mutating func enter(_ next: GlobeScale) {
        guard scale != next else { return }
        scale = next
        restoreAutomaticStyle()
        discardPins()
    }

    mutating func restoreAutomaticStyle() { style = scale == .map ? .standard : .satellite }

    mutating func toggleStyle() { style = style.toggled }

    mutating func discardPins() { markers = scale == .map ? .awaitingPhotos : .places }

    mutating func publish(_ clusters: [MapReviewCluster]) {
        guard scale == .map else { return }
        markers = .photos(UUID(), clusters)
    }
}
