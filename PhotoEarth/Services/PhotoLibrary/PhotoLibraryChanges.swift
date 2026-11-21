import Foundation
import Photos

nonisolated protocol PhotoLibraryUpdating: PhotoLibraryProviding {
    func currentChangeToken() async throws -> Data
    func enumeratePhotos(_ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> Int
    func enumerateChanges(since token: Data, _ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> LibraryChangeResult
    func observeChanges(_ onChange: @escaping @Sendable () -> Void)
    func stopObservingChanges()
}

extension PhotoKitLibrary: PhotoLibraryUpdating {
    func prepareScope(activate: Bool = true) async throws -> (scope: String, revision: Int) {
        let preferences = TravelScanPreferences.load()
        let scope = try await Task.detached(priority: .utility) { try TravelScanScope.fetch(preferences) }.value
        if activate { return try await scanLedger.prepare(scope) }
        return try await scanLedger.publicationState(for: scope)
    }

    func publicationKey(access: PhotoLibraryAccess, catalogVersion: String, locale: String, activateScope: Bool = false) async throws -> ScanPublicationKey {
        let scope = try await prepareScope(activate: activateScope)
        return ScanPublicationKey(access: access == .limited ? "limited" : "authorized", scope: scope.scope, cameraRevision: scope.revision, catalog: catalogVersion, locale: locale)
    }

    /// Publishes lightweight metadata first. Original resource checks are local-only
    /// and serial, rechecking the asset version before accepting evidence.
    func auditCameras(removed: @escaping @Sendable (Set<String>) async -> Void, shouldYield: @escaping @Sendable () async -> Bool) async throws -> Bool {
        let ledger = scanLedger
        let job = Task.detached(priority: .utility) {
            var anyRemoved = false
            let started = ContinuousClock.now
            while true {
                try Task.checkCancellation()
                if await shouldYield() { return anyRemoved }
                let batch = try await ledger.pending()
                if batch.isEmpty { return anyRemoved }
                for item in batch {
                    try Task.checkCancellation()
                    let original = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject
                    var evidence = CameraEvidence.unknown
                    if let asset = original, asset.modificationDate?.timeIntervalSinceReferenceDate == item.modified {
                        evidence = await CameraEvidenceReader.read(asset)
                        let current = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject
                        if current == nil || current?.modificationDate != asset.modificationDate { evidence = .unknown }
                    }
                    if try await ledger.record(evidence, for: item) {
                        anyRemoved = true
                        await removed([item.id])
                    }
                    if await shouldYield() { return anyRemoved }
                }
                // Publish confirmed exclusions during long audits. The next pass stages
                // only the new removals and reconciles the Photos change token.
                if anyRemoved, started.duration(to: .now) >= .seconds(10) { return true }
            }
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    func currentChangeToken() async throws -> Data {
        try Self.archive(PHPhotoLibrary.shared().currentChangeToken)
    }

    func enumeratePhotos(_ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> Int {
        let ledger = scanLedger
        let worker = Task.detached(priority: .utility) {
            try Self.checkAvailability()
            let sweep = UUID().uuidString
            let assetGroups = [
                PHAsset.fetchAssets(with: .image, options: nil),
                PHAsset.fetchAssets(with: .video, options: nil),
            ]
            let total = assetGroups.reduce(0) { $0 + $1.count }
            var checked = 0
            for assets in assetGroups {
                for start in stride(from: 0, to: assets.count, by: 256) {
                    try Task.checkCancellation()
                    let end = min(start + 256, assets.count)
                    let batch = autoreleasepool { (start..<end).map { ScanAssetMetadata(assets.object(at: $0)) } }
                    let records = try await ledger.filter(batch, sweep: sweep)
                    checked += end - start
                    try await receive(PhotoMetadataBatch(records: records, checked: checked, total: total))
                }
            }
            if total == 0 { try await receive(PhotoMetadataBatch(records: [], checked: 0, total: 0)) }
            try Self.checkAvailability()
            try await ledger.finishSweep(sweep)
            return try await ledger.sourceCount()
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func enumerateChanges(since token: Data, _ receive: @escaping @Sendable (PhotoMetadataBatch) async throws -> Void) async throws -> LibraryChangeResult {
        let ledger = scanLedger
        let worker = Task.detached(priority: .utility) {
            try Self.checkAvailability()
            let start: PHPersistentChangeToken
            do {
                guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else {
                    throw LibraryPreparationError.expiredToken
                }
                start = decoded
            } catch { throw LibraryPreparationError.expiredToken }
            let changes: PHPersistentChangeFetchResult
            do { changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: start) }
            catch { throw Self.changeReadError(error) }
            var safeToken = token
            var changed = 0
            for change in changes {
                try Task.checkCancellation()
                let details: PHPersistentObjectChangeDetails
                do { details = try change.changeDetails(for: .asset) }
                catch { throw Self.changeReadError(error) }
                // Photos gives identifier sets. Fetch asset metadata in bounded
                // chunks, including updated assets that previously had no GPS.
                let identifiers = details.insertedLocalIdentifiers.union(details.updatedLocalIdentifiers)
                let ids = Array(identifiers)
                for start in stride(from: 0, to: ids.count, by: 256) {
                    try Task.checkCancellation()
                    let batchIDs = Array(ids[start..<min(start + 256, ids.count)])
                    let batch = autoreleasepool {
                        let assets = PHAsset.fetchAssets(withLocalIdentifiers: batchIDs, options: nil)
                        return (0..<assets.count).compactMap { index -> ScanAssetMetadata? in
                            let asset = assets.object(at: index)
                            guard asset.mediaType == .image || asset.mediaType == .video else { return nil }
                            return ScanAssetMetadata(asset)
                        }
                    }
                    let records = try await ledger.filter(batch)
                    try await ledger.remove(Array(Set(batchIDs).subtracting(batch.map(\.id))))
                    changed += batchIDs.count
                    try await receive(PhotoMetadataBatch(records: records, removedIDs: batchIDs, checked: changed))
                }
                let deleted = Array(details.deletedLocalIdentifiers)
                for start in stride(from: 0, to: deleted.count, by: 256) {
                    let ids = Array(deleted[start..<min(start + 256, deleted.count)])
                    try await ledger.remove(ids)
                    changed += ids.count
                    try await receive(PhotoMetadataBatch(records: [], removedIDs: ids, checked: changed))
                }
                safeToken = try Self.archive(change.changeToken)
            }
            try Self.checkAvailability()
            return LibraryChangeResult(token: safeToken,
                                       sourcePhotoCount: try await ledger.sourceCount(),
                                       changedAssetCount: changed)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
        changeObserver.setCallback(onChange)
        PHPhotoLibrary.shared().register(changeObserver)
    }

    func stopObservingChanges() {
        PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
        changeObserver.setCallback(nil)
    }

    private nonisolated static func changeReadError(_ error: Error) -> Error {
        let value = error as NSError
        if value.domain == PHPhotosErrorDomain,
           [PHPhotosError.Code.persistentChangeTokenExpired.rawValue,
            PHPhotosError.Code.persistentChangeDetailsUnavailable.rawValue].contains(value.code) {
            return LibraryPreparationError.expiredToken
        }
        return error
    }

    private nonisolated static func archive(_ token: PHPersistentChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private nonisolated static func checkAvailability() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              PHPhotoLibrary.shared().unavailabilityReason == nil else { throw LibraryPreparationError.unavailable }
    }

    nonisolated static func record(_ asset: PHAsset) -> PhotoAssetRecord? {
        let mediaKind: PhotoMediaKind
        switch asset.mediaType {
        case .image:
            mediaKind = asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        case .video:
            mediaKind = .video
        default:
            return nil
        }
        guard !asset.isHidden, !asset.mediaSubtypes.contains(.photoScreenshot), !asset.mediaSubtypes.contains(.videoScreenRecording),
              let location = asset.location, let date = asset.creationDate, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let coordinate = GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        guard coordinate.isValid else { return nil }
        return PhotoAssetRecord(id: asset.localIdentifier, coordinate: coordinate, creationDate: date,
                                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                isFavorite: asset.isFavorite, mediaKind: mediaKind, duration: asset.duration,
                                altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
                                horizontalAccuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                                verticalAccuracyMeters: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil)
    }


}

/// PhotoKit invokes observers off the main actor. Only a notification crosses
/// this boundary; private asset IDs and PHChange objects are never published.
nonisolated final class PhotoLibraryChangeRelay: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func setCallback(_ callback: (@Sendable () -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.callback = callback
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?()
    }
}
