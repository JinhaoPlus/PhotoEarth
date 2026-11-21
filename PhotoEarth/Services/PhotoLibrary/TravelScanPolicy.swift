import CoreLocation
import CryptoKit
import Foundation
import Photos

nonisolated enum CameraEvidence: Int, Codable, Sendable {
    case unknown, identified, confirmedMissing
}

nonisolated enum TravelScanDecision: Int, CaseIterable, Sendable {
    case eligible, unavailable, excludedAlbum, screenCapture, invalidDate, missingLocation, noCamera, pendingCamera

    var included: Bool { self == .eligible || self == .pendingCamera }

    static func decide(available: Bool, excluded: Bool, screen: Bool, dated: Bool, located: Bool,
                       evidence: CameraEvidence, excludesMissingCamera: Bool) -> Self {
        guard available else { return .unavailable }
        if excluded { return .excludedAlbum }
        if screen { return .screenCapture }
        if !dated { return .invalidDate }
        if !located { return .missingLocation }
        if evidence == .unknown { return .pendingCamera }
        if excludesMissingCamera && evidence == .confirmedMissing { return .noCamera }
        return .eligible
    }
}

nonisolated struct TravelScanPreferences: Codable, Equatable, Sendable {
    var excludedAlbums: Set<String> = []
    var excludesMissingCamera = true
    private static let key = "travelScan.preferences.v1"
    static var hasSavedChoice: Bool { UserDefaults.standard.data(forKey: key) != nil }
    static func load() -> Self {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.key) }
}

nonisolated struct ScanAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let count: Int
}

nonisolated struct TravelScanScope: Sendable {
    var preferences = TravelScanPreferences()
    var members: Set<String> = []
    var limitedIdentifiers: Set<String> = []
    var fingerprint: String {
        var digest = SHA256()
        for value in [preferences.excludesMissingCamera ? "1" : "0"] + preferences.excludedAlbums.sorted() + ["|"] + members.sorted() + ["|limited|"] + limitedIdentifiers.sorted() {
            digest.update(data: Data(value.utf8))
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fetch(_ preferences: TravelScanPreferences, saveVerification: Bool = true) throws -> Self {
        let library = PHPhotoLibrary.shared()
        let status = try availableAccess()
        let token = library.currentChangeToken
        var result = Self(preferences: preferences)
        if status == .limited {
            let visible = PHAsset.fetchAssets(with: nil)
            result.limitedIdentifiers = Set((0..<visible.count).map { visible.object(at: $0).localIdentifier })
        }
        guard !preferences.excludedAlbums.isEmpty else { return result }
        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(preferences.excludedAlbums), options: nil)
        // An inaccessible collection is ambiguous under limited access. Never publish a wider scope.
        let visible = Set((0..<albums.count).map { albums.object(at: $0).localIdentifier })
        let missing = preferences.excludedAlbums.subtracting(visible)
        if !missing.isEmpty {
            let deleted = try confirmedAlbumDeletions()
            result.preferences.excludedAlbums = try verifiedSelection(preferences.excludedAlbums, readable: visible, deleted: deleted)
        }
        var seen = Set<String>()
        for index in 0..<albums.count {
            try Task.checkCancellation()
            let album = albums.object(at: index)
            guard seen.insert(album.localIdentifier).inserted else { continue }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            for start in stride(from: 0, to: assets.count, by: 256) {
                try Task.checkCancellation()
                autoreleasepool {
                    for i in start..<min(start + 256, assets.count) { result.members.insert(assets.object(at: i).localIdentifier) }
                }
            }
        }
        guard try availableAccess() == status else { throw LibraryPreparationError.unavailable }
        if saveVerification && TravelScanPreferences.load() == preferences {
            if result.preferences != preferences { try result.preferences.save() }
            if let bytes = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(bytes, forKey: albumTokenKey)
            }
        }
        return result
    }

    private static let albumTokenKey = "travelScan.verifiedAlbumToken.v1"

    static func verifiedSelection(_ selected: Set<String>, readable: Set<String>, deleted: Set<String>) throws -> Set<String> {
        let missing = selected.subtracting(readable)
        guard missing.isSubset(of: deleted) else { throw LibraryPreparationError.unavailable }
        return selected.subtracting(missing)
    }

    private static func availableAccess() throws -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard [.authorized, .limited].contains(status), PHPhotoLibrary.shared().unavailabilityReason == nil else {
            throw LibraryPreparationError.unavailable
        }
        return status
    }

    private static func confirmedAlbumDeletions() throws -> Set<String> {
        do {
            guard let bytes = UserDefaults.standard.data(forKey: albumTokenKey),
                  let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: bytes)
            else { throw LibraryPreparationError.unavailable }
            var deleted = Set<String>()
            let history = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            for change in history {
                try Task.checkCancellation()
                deleted.formUnion(try change.changeDetails(for: .assetCollection).deletedLocalIdentifiers)
            }
            return deleted
        } catch is CancellationError { throw CancellationError() }
        catch { throw LibraryPreparationError.unavailable }
    }

    static func albums() throws -> [ScanAlbum] {
        _ = try availableAccess()
        try Task.checkCancellation()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var seen = Set<String>()
        return (0..<albums.count).compactMap { i -> ScanAlbum? in
            let album = albums.object(at: i)
            guard seen.insert(album.localIdentifier).inserted else { return nil }
            let contents = PHAsset.fetchAssets(in: album, options: nil)
            let count = Set((0..<contents.count).map { contents.object(at: $0).localIdentifier }).count
            return ScanAlbum(id: album.localIdentifier, title: album.localizedTitle ?? "", count: count)
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
}

nonisolated struct ScanAssetMetadata: Sendable {
    let id: String
    let modified: Date?
    let available: Bool
    let screen: Bool
    let dated: Bool
    let located: Bool
    let record: PhotoAssetRecord?

}

extension ScanAssetMetadata {
    nonisolated init(_ asset: PHAsset) {
        id = asset.localIdentifier
        modified = asset.modificationDate
        available = !asset.isHidden && (asset.mediaType == .image || asset.mediaType == .video)
        screen = asset.mediaSubtypes.contains(.photoScreenshot) || asset.mediaSubtypes.contains(.videoScreenRecording)
        dated = asset.creationDate?.timeIntervalSinceReferenceDate.isFinite == true
        located = asset.location.map { CLLocationCoordinate2DIsValid($0.coordinate) } ?? false
        record = PhotoKitLibrary.record(asset)
    }
}

/// A persisted publication can survive a catalog or evidence refresh while its
/// scope remains visible. Any authorization or membership change withdraws it.
nonisolated struct ScanPublicationKey: Codable, Equatable, Sendable {
    let access: String
    let scope: String
    let cameraRevision: Int
    let catalog: String
    let locale: String
    // Older caches keyed city labels by language only, even for regional publications.
    var labelLocaleVersion: Int? = 1
    var visitGroupingVersion: Int? = StreamingTravelClusterer.publicationVersion

    enum Transition { case reuse, rebuild, withdraw }
    func transition(from serialized: String?) -> Transition {
        guard let serialized,
              let previous = try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8)),
              previous.scope == scope, previous.access == access else { return .withdraw }
        return previous == self ? .reuse : .rebuild
    }

    func changesOnlyLocale(from serialized: String) -> Bool {
        guard let old = try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8)) else { return false }
        return (old.locale != locale || old.labelLocaleVersion != labelLocaleVersion)
            && old.scope == scope && old.access == access
            && old.catalog == catalog && old.cameraRevision == cameraRevision
            && old.visitGroupingVersion == visitGroupingVersion
    }

    /// Geographic revisions change grouping, while the published asset scope
    /// and camera decisions still describe the same eligible metadata.
    func canRegroupStoredMetadata(from serialized: String?) -> Bool {
        guard access == "authorized", let serialized,
              let previous = try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8)),
              previous.scope == scope, previous.access == access,
              previous.cameraRevision == cameraRevision else { return false }
        return previous.catalog != catalog || previous.visitGroupingVersion != visitGroupingVersion
    }

    func canReuseGeography(from serialized: String?) -> Bool {
        guard let serialized,
              let previous = try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8)) else { return false }
        return previous.access == access && previous.scope == scope && previous.cameraRevision == cameraRevision
            && previous.catalog == catalog && previous.visitGroupingVersion == visitGroupingVersion
            && previous.locale == locale && previous.labelLocaleVersion == labelLocaleVersion
    }

    func previousCameraRevision(from serialized: String?) -> Int? {
        guard let serialized,
              let previous = try? JSONDecoder().decode(Self.self, from: Data(serialized.utf8)),
              previous.scope == scope, previous.access == access, previous.catalog == catalog,
              previous.locale == locale, previous.labelLocaleVersion == labelLocaleVersion,
              previous.visitGroupingVersion == visitGroupingVersion,
              previous.cameraRevision < cameraRevision else { return nil }
        return previous.cameraRevision
    }

    func serialized() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
