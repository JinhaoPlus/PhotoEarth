import Foundation

nonisolated enum LibraryPreparationMode: String, Codable, Sendable {
    case initial, update, labels, rebuild
}

nonisolated enum LibraryPreparationPhase: String, Codable, Sendable {
    case idle, checking, organizing, labeling, saving, waiting, paused, complete, partial, failed

    var isWorking: Bool { [.checking, .organizing, .labeling, .saving].contains(self) }
}

nonisolated enum LibraryPreparationNotice: String, Codable, Sendable {
    case restartAfterSave
    case libraryUnavailable
    case saveFailed
    case waitForWall
    case geocoderBusy
    case noLocatedPhotos
    case savedOnDevice
    case partialLabels

    func text(locale: Locale = AppLocalization.locale) -> String {
        switch self {
        case .restartAfterSave:
            AppLocalization.string("preparation.message.restart_after_save", defaultValue: "Photos will be checked again after this step is saved.", locale: locale)
        case .libraryUnavailable:
            AppLocalization.string("preparation.message.library_unavailable", defaultValue: "The photo library is temporarily unavailable. Saved progress will be kept.", locale: locale)
        case .saveFailed:
            AppLocalization.string("preparation.message.save_failed", defaultValue: "The update could not be saved. Try again later; earlier progress is safe.", locale: locale)
        case .waitForWall:
            AppLocalization.string("preparation.message.wait_for_wall", defaultValue: "Photo information is ready. Updating will continue after you leave the photo wall.", locale: locale)
        case .geocoderBusy:
            AppLocalization.string("preparation.message.geocoder_busy", defaultValue: "Place naming is paused. Your progress is saved and will resume later.", locale: locale)
        case .noLocatedPhotos:
            AppLocalization.string("preparation.message.no_located_photos", defaultValue: "No accessible photos or videos have location data yet. Future changes will update automatically.", locale: locale)
        case .savedOnDevice:
            AppLocalization.string("preparation.message.saved_on_device", defaultValue: "Your scan results are saved on this Apple TV.", locale: locale)
        case .partialLabels:
            AppLocalization.string("preparation.message.partial_labels", defaultValue: "Some locations have no reliable city or country yet. Their photos and coordinates remain available.", locale: locale)
        }
    }
}

/// A small, durable checkpoint. Photo rows and individual retry jobs stay in SQLite.
nonisolated struct LibraryPreparationProgress: Codable, Equatable, Sendable {
    var mode: LibraryPreparationMode = .update
    var phase: LibraryPreparationPhase = .idle
    var checkedPhotos = 0
    var totalPhotos = 0
    var locatedPhotos = 0
    var totalPlaces = 0
    var completePlaces = 0
    var coveredPhotos = 0
    var attemptedPlaces = 0
    var remainingPlaces = 0
    var retryAt: Date?
    var userPaused = false
    var needsMetadata = false
    var notice: LibraryPreparationNotice?
    var updatedAt = Date()

    var fraction: Double? {
        let counts: (Int, Int)
        switch phase {
        case .checking: counts = (checkedPhotos, totalPhotos)
        case .organizing: counts = (checkedPhotos, locatedPhotos)
        case .labeling, .complete, .partial: counts = (completePlaces, totalPlaces)
        default: return nil
        }
        guard counts.1 > 0 else { return nil }
        return min(1, max(0, Double(counts.0) / Double(counts.1)))
    }

    var title: String {
        switch phase {
        case .idle: AppLocalization.string("preparation.title.idle", defaultValue: "Photos & Places")
        case .checking: AppLocalization.string("preparation.title.checking", defaultValue: "Checking Photos")
        case .organizing: AppLocalization.string("preparation.title.organizing", defaultValue: "Organizing Places")
        case .labeling: AppLocalization.string("preparation.title.labeling", defaultValue: "Adding Place Names")
        case .saving: AppLocalization.string("preparation.title.saving", defaultValue: "Saving Updates")
        case .waiting: AppLocalization.string("preparation.title.waiting", defaultValue: "Waiting to Continue")
        case .paused: AppLocalization.string("preparation.title.paused", defaultValue: "Library Scan Paused")
        case .complete: locatedPhotos == 0
            ? AppLocalization.string("preparation.title.checked", defaultValue: "Photo Check Complete")
            : AppLocalization.string("preparation.title.complete", defaultValue: "Scan Complete")
        case .partial: AppLocalization.string("preparation.title.partial", defaultValue: "Place Preparation Complete for Now")
        case .failed: AppLocalization.string("preparation.title.failed", defaultValue: "Update Not Complete")
        }
    }

    var countText: String {
        switch phase {
        case .checking: totalPhotos > 0
            ? AppLocalization.format("preparation.count.photos", defaultValue: "Photos checked: %1$@ / %2$@", AppLocalization.number(checkedPhotos), AppLocalization.number(totalPhotos))
            : AppLocalization.string("preparation.count.checking_changes", defaultValue: "Checking for photo changes")
        case .organizing:
            AppLocalization.format("preparation.count.located", defaultValue: "Photos with location data: %1$@ / %2$@", AppLocalization.number(checkedPhotos), AppLocalization.number(locatedPhotos))
        case .labeling:
            AppLocalization.format("preparation.count.places", defaultValue: "Places named: %1$@ / %2$@", AppLocalization.number(completePlaces), AppLocalization.number(totalPlaces))
        case .paused, .waiting: needsMetadata
            ? (totalPhotos > 0
                ? AppLocalization.format("preparation.count.checked", defaultValue: "Photos checked: %1$@ / %2$@", AppLocalization.number(checkedPhotos), AppLocalization.number(totalPhotos))
                : AppLocalization.string("preparation.count.metadata_pending", defaultValue: "Photo information check not complete"))
            : AppLocalization.format("preparation.count.remaining", defaultValue: "%lld places still need names", Int64(remainingPlaces))
        case .partial:
            AppLocalization.format("preparation.count.remaining", defaultValue: "%lld places still need names", Int64(remainingPlaces))
        case .complete:
            AppLocalization.format("preparation.count.complete", defaultValue: "Photos with location data: %1$@ · Places: %2$@", AppLocalization.number(locatedPhotos), AppLocalization.number(totalPlaces))
        case .failed: AppLocalization.string("preparation.count.saved", defaultValue: "Your saved memories are still here")
        case .saving: AppLocalization.string("preparation.count.saving", defaultValue: "Saving progress on this Apple TV")
        case .idle: AppLocalization.string("preparation.count.idle", defaultValue: "View photos and places")
        }
    }
}

nonisolated struct PhotoMetadataBatch: Sendable {
    var records: [PhotoAssetRecord]
    var removedIDs: [String] = []
    var checked = 0
    var total = 0
}

nonisolated struct LibraryChangeResult: Sendable {
    let token: Data
    let sourcePhotoCount: Int
    let changedAssetCount: Int
}

nonisolated struct LibrarySyncState: Sendable {
    var token: Data?
    var lastFullCheck: Date?
    var lastCheck: Date?
    var authorization: String?
}

nonisolated struct PlaceLabelJob: Sendable {
    let place: TravelPlace
    let attempts: Int
    let nextRetryAt: Date?
}

nonisolated enum LibraryPreparationError: Error {
    case unavailable, expiredToken, staleRun, saveFailed
}

/// Exact query basis; geographic display grids never confer city/country validity.
nonisolated enum PlaceLabelBasis {
    static let version = WorldCityAtlas.revision
    static func key(_ coordinate: GeoCoordinate) -> String {
        "\(version):\(coordinate.latitude.bitPattern):\(coordinate.longitude.bitPattern)"
    }
}

nonisolated struct ScanDiscovery: Equatable, Sendable {
    let revision: Int
    let places: [TravelPlace]
}
