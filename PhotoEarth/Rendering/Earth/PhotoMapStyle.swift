import MapKit

enum PhotoMapStyle: Sendable {
    case satellite, standard

    var toggled: Self { self == .satellite ? .standard : .satellite }

    @MainActor var title: String {
        switch self {
        case .satellite: AppLocalization.string("review.style.satellite", defaultValue: "Satellite")
        case .standard: AppLocalization.string("review.style.map", defaultValue: "Map")
        }
    }

    @MainActor func configuration(realisticTerrain: Bool = true) -> MKMapConfiguration {
        switch self {
        case .satellite: return MKImageryMapConfiguration(elevationStyle: .realistic)
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: realisticTerrain ? .realistic : .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = .excludingAll
            configuration.showsTraffic = false
            return configuration
        }
    }
}
