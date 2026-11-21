import Foundation
import Photos

nonisolated enum JourneyShelfPhoto {
    static func access() -> PHAuthorizationStatus? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard (status == .authorized || status == .limited), PHPhotoLibrary.shared().unavailabilityReason == nil else { return nil }
        return status
    }

    enum History: String {
        case current, noAccess, accessChanged, missingToken, invalidToken, unreadableHistory, changesPending
    }

    static func history(_ data: Data?, limited: Bool) -> History {
        guard let status = access() else { return .noAccess }
        guard limited == (status == .limited) else { return .accessChanged }
        guard let data else { return .missingToken }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data) else { return .invalidToken }
        guard let changes = try? PHPhotoLibrary.shared().fetchPersistentChanges(since: token) else { return .unreadableHistory }
        for _ in changes { return .changesPending }
        return .current
    }

    static func isCurrent(_ snapshot: JourneyShelfSnapshot) -> Bool {
        history(snapshot.historyToken, limited: snapshot.limitedAccess) == .current
    }

    struct Delivery {
        var history: History
        var touched = Set<String>()
        var deletedCovers = Set<String>()
        var uncertainScope = false
        var oversizedWallDelta = false

        var readable: Bool { !uncertainScope && (history == .current || history == .changesPending) }
        func permits(_ item: JourneyShelfItem, proof: String?) -> Bool {
            readable && !deletedCovers.contains(item.assetID) && proof == item.photoProof
        }
    }

    /// New arrivals do not invalidate existing posters. Edits/deletions require new
    /// proofs for the affected assets. A change in limited access or an excluded
    /// album's membership can affect visibility outside those IDs; wait for sync.
    static func delivery(_ snapshot: JourneyShelfSnapshot, checkingWall: Bool = false) -> Delivery {
        guard let status = access() else { return Delivery(history: .noAccess) }
        guard snapshot.limitedAccess == (status == .limited) else { return Delivery(history: .accessChanged) }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: snapshot.historyToken) else {
            return Delivery(history: .invalidToken)
        }
        guard let changes = try? PHPhotoLibrary.shared().fetchPersistentChanges(since: token) else { return Delivery(history: .unreadableHistory) }
        let watched = Set(snapshot.items.map(\.assetID))
        var result = Delivery(history: .current)
        for change in changes {
            result.history = .changesPending
            if snapshot.limitedAccess { result.uncertainScope = true; break }
            guard let assets = try? change.changeDetails(for: .asset),
                  let albums = try? change.changeDetails(for: .assetCollection) else { return Delivery(history: .unreadableHistory) }
            if snapshot.mayHaveChangedExcludedAlbum(albums.updatedLocalIdentifiers.union(albums.deletedLocalIdentifiers)) {
                result.uncertainScope = true
                break
            }
            let modified = assets.updatedLocalIdentifiers.union(assets.deletedLocalIdentifiers)
            result.deletedCovers.formUnion(watched.intersection(assets.deletedLocalIdentifiers))
            if checkingWall && !result.oversizedWallDelta && modified.count + result.touched.count <= 8_192 {
                result.touched.formUnion(modified)
            } else {
                if checkingWall { result.oversizedWallDelta = true }
                result.touched.formUnion(watched.intersection(modified))
            }
        }
        return result
    }

    static func validatesAllMarkers(_ snapshot: JourneyShelfSnapshot) -> Bool {
        let validity = delivery(snapshot)
        guard validity.readable else { return false }
        let proofs = currentProofs(for: snapshot.markerItems.map(\.assetID))
        return snapshot.markerItems.allSatisfy { validity.permits($0, proof: proofs[$0.assetID]) }
    }

    static func currentProofs(for identifiers: [String]) -> [String: String] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var proofs: [String: String] = [:]
        assets.enumerateObjects { asset, _, _ in proofs[asset.localIdentifier] = proof(for: asset) }
        return proofs
    }

    /// Recheck the actual asset and its album memberships even if the host is closed.
    /// Changes to time, position, pixels or membership suppress this publication.
    static func proof(for asset: PHAsset, excluding albums: Set<String> = []) -> String? {
        guard !asset.isHidden, let date = asset.creationDate, let location = asset.location,
              CLLocationCoordinate2DIsValid(location.coordinate), !asset.mediaSubtypes.contains(.photoScreenshot),
              !asset.mediaSubtypes.contains(.videoScreenRecording), asset.mediaType == .image || asset.mediaType == .video else { return nil }
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var memberships = Set<String>()
        collections.enumerateObjects { collection, _, _ in memberships.insert(collection.localIdentifier) }
        guard memberships.isDisjoint(with: albums) else { return nil }
        let details = [asset.localIdentifier, String(date.timeIntervalSinceReferenceDate.bitPattern),
                       String(asset.modificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0),
                       String(location.coordinate.latitude.bitPattern), String(location.coordinate.longitude.bitPattern),
                       String(asset.pixelWidth), String(asset.pixelHeight)]
        return JourneyShelfLink.digest(details + memberships.sorted())
    }
}
