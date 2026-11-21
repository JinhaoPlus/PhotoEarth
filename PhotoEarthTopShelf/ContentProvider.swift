import Foundation
import Photos
import TVServices
import UIKit

class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        await ShelfContentLoader.shared.load()
    }
}

/// TVServices may request a refresh while the previous thumbnail is still arriving.
/// Serialize the handoff so an old callback cannot re-create an already purged file.
@MainActor private final class ShelfContentLoader {
    static let shared = ShelfContentLoader()
    private var pending: Task<(any TVTopShelfContent)?, Never>?
    private var ticket = UUID()

    func load() async -> (any TVTopShelfContent)? {
        let previous = pending
        let current = UUID()
        ticket = current
        let task = Task {
            _ = await previous?.value
            return await Self.build()
        }
        pending = task
        let result = await task.value
        if current == ticket { pending = nil }
        return result
    }

    nonisolated private static func build(retryOnNewPublication: Bool = true) async -> (any TVTopShelfContent)? {
        let bundle = Bundle(for: ContentProvider.self)
        let globeTitle = bundle.localizedString(forKey: "home.explore_globe", value: "Explore the Globe", table: nil)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("JourneyShelfPreviews", isDirectory: true)
#if DEBUG
        var status = "nil-no-current-publication"
        var published = 0
        var deliveredDates: [Date] = []
        var readablePosters = 0
        var recordReceipt = true
        defer { if recordReceipt { JourneyShelfKeychain.noteProviderResult(status, count: published, endDates: deliveredDates, readable: readablePosters) } }
#endif
        guard let snapshot = JourneyShelfKeychain.read(), snapshot.imageVersion == JourneyShelfSnapshot.currentImageVersion, snapshot.scanScope != nil else {
#if DEBUG
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .notDetermined: status = "nil-photos-not-authorized"
            case .restricted, .denied: status = "nil-photos-access-revoked"
            default: break
            }
#endif
            try? FileManager.default.removeItem(at: cache)
            return nil
        }
        let initial = JourneyShelfPhoto.delivery(snapshot)
#if DEBUG
        status = "nil-" + (initial.uncertainScope ? "unverified-scan-scope" : initial.history.rawValue)
#endif
        guard initial.readable else {
            try? FileManager.default.removeItem(at: cache)
            return nil
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: snapshot.items.map(\.assetID), options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var allowedFiles = Set<URL>()
        let proofs = byID.compactMapValues { JourneyShelfPhoto.proof(for: $0) }
        let valid = snapshot.eligiblePosters(proofs: proofs).filter { initial.permits($0.item, proof: proofs[$0.item.assetID]) }
        var images: [String: URL] = [:]
        var missing: [(Int, JourneyShelfItem)] = []
        func preview(slot: Int, entry: JourneyShelfItem, network: Bool) async -> URL? {
            guard !Task.isCancelled, let asset = byID[entry.assetID] else { return nil }
            if let jpeg = JourneyShelfKeychain.poster(at: slot, in: snapshot), let url = JourneyShelfImageURL.make(jpeg: jpeg) { return url }
            let file = cache.appendingPathComponent(JourneyShelfLink.digest(["poster-2x3", entry.route, entry.photoProof]) + ".jpg")
            if let jpeg = try? Data(contentsOf: file), let url = JourneyShelfImageURL.make(jpeg: jpeg) {
                allowedFiles.insert(file)
                return url
            }
            guard ContinuousClock.now < deadline,
                  let jpeg = await ShelfPreviewRequest().jpeg(asset: asset, network: network, deadline: deadline),
                  let url = JourneyShelfImageURL.make(jpeg: jpeg) else { return nil }
            try? jpeg.write(to: file, options: .atomic)
            allowedFiles.insert(file)
            return url
        }
        for (slot, entry) in valid where entry.awaitingCover != true {
            if let url = await preview(slot: slot, entry: entry, network: false) { images[entry.route] = url }
            else { missing.append((slot, entry)) }
        }
        // Spend the limited network budget on the newest missing posters even if older
        // posters are already cached. Completion order must never move a journey.
        for (slot, entry) in missing.prefix(2) {
            if let url = await preview(slot: slot, entry: entry, network: true) { images[entry.route] = url }
        }
        let final = JourneyShelfPhoto.delivery(snapshot)
        guard final.readable else {
            try? FileManager.default.removeItem(at: cache)
#if DEBUG
            status = "nil-" + (final.uncertainScope ? "unverified-scan-scope" : final.history.rawValue)
#endif
            return nil
        }
        let finalProofs = final.touched.isEmpty ? proofs : JourneyShelfPhoto.currentProofs(for: valid.map { $0.item.assetID })
        let entries = valid.map { $0.item }.filter { final.permits($0, proof: finalProofs[$0.assetID]) }
        let routes = Set(entries.map(\.route))
        images = images.filter { routes.contains($0.key) }
        let eligibleFiles = Set(entries.map { cache.appendingPathComponent(JourneyShelfLink.digest(["poster-2x3", $0.route, $0.photoProof]) + ".jpg") })
        allowedFiles.formIntersection(eligibleFiles)
        for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] where !allowedFiles.contains(file) {
            try? FileManager.default.removeItem(at: file)
        }
        guard !images.isEmpty else {
#if DEBUG
            status = entries.isEmpty ? "nil-no-eligible-city" : "nil-no-readable-poster"
#endif
            return nil
        }
        let language = bundle.preferredLocalizations.first.map { base in
            Locale.autoupdatingCurrent.region.map { base + "-" + $0.identifier } ?? base
        }
        let titles = JourneyShelfItem.displayTitles(in: entries, language: language)
        let placeholder = images.count == entries.count ? nil : await ShelfPreviewRequest.blurredPosterURL()
        let items = entries.compactMap { entry -> TVTopShelfSectionedItem? in
            guard let link = JourneyShelfLink.url(entry.route) else { return nil }
            let item = TVTopShelfSectionedItem(identifier: entry.route)
            item.title = titles[entry.route]
            item.displayAction = TVTopShelfAction(url: link)
            let image = images[entry.route] ?? placeholder
            item.setImageURL(image, for: .screenScale1x)
            item.setImageURL(image, for: .screenScale2x)
            return item
        }
        let allMarkersCurrent = snapshot.markerItems.allSatisfy { routes.contains($0.route) }
        let privateImage = allMarkersCurrent ? snapshot.globeScope.flatMap(JourneyShelfKeychain.globe(for:))
            .flatMap(JourneyShelfImageURL.globe(jpeg:)) : nil
        guard JourneyShelfKeychain.read() == snapshot, let access = JourneyShelfPhoto.access(),
              snapshot.limitedAccess == (access == .limited) else {
            try? FileManager.default.removeItem(at: cache)
            if retryOnNewPublication {
#if DEBUG
                recordReceipt = false
#endif
                return await build(retryOnNewPublication: false)
            }
#if DEBUG
            status = "nil-publication-replaced"
#endif
            return nil
        }
#if DEBUG
        published = items.count
        deliveredDates = entries.compactMap(\.endDate)
        readablePosters = images.count
        status = (privateImage == nil ? "section-public-map" : "section-private-native-map")
            + (final.history == .changesPending ? "-verified-delta" : "")
#endif
        let globeImage = privateImage ?? bundle.url(forResource: "EarthShelfGlobePreview", withExtension: "jpg")
            .flatMap { try? Data(contentsOf: $0) }.flatMap(JourneyShelfImageURL.globe(jpeg:))
        return JourneyShelfLayout.content(globeTitle: globeTitle, globeImage: globeImage, journeys: items, readablePosterRoutes: Set(images.keys))
    }
}
