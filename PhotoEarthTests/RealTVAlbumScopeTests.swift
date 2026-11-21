#if os(tvOS) && !targetEnvironment(simulator)
import Foundation
import Photos
import Testing
@testable import PhotoEarth

struct RealTVAlbumScopeTests {
    /// Uses the TV's current permission and existing regular albums. Only the isolated
    /// ledger and index are writable. Raw asset IDs and album names stay out of logs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOEARTH_REAL_TV_ALBUM_SCOPE"] == "1"))
    func excludingOneReadableAlbumWithdrawsAndRestoresItsTravelPhotos() async throws {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try #require(access == .authorized || access == .limited, "Grant Photos read access on the TV before running the gate.")
        let original = TravelScanPreferences.load()
        defer {
            let originalStillSelected = TravelScanPreferences.load() == original
            #expect(originalStillSelected, "The gate must leave the user's scan settings intact.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = TravelScanLedger(url: root.appendingPathComponent("evidence.sqlite"))
        let index = SQLiteTravelIndexStore(databaseURL: root.appendingPathComponent("index.sqlite"))
        let base = try TravelScanScope.fetch(original, saveVerification: false)
        let sample = try findSample(base)
        var excludedPreferences = base.preferences
        excludedPreferences.excludedAlbums.insert(sample.album)
        let excluded = try TravelScanScope.fetch(excludedPreferences, saveVerification: false)
        let testRows = sample.inside + sample.outside
        let insideIDs = Set(sample.inside.map(\.id))
        let controls = Set(sample.outside.map(\.id))
        let actualOverlap = excluded.members.intersection(Set(testRows.map(\.id)))
        let albumWasReadCorrectly = actualOverlap == insideIDs
        try #require(albumWasReadCorrectly, "The selected collection's actual members must match the independent PhotoKit fetch.")

        // Initial metadata goes through the regular decision/ledger. Inspect just two
        // local originals on each side, subject to the shipping timeout and byte cap.
        _ = try await ledger.prepare(base)
        _ = try await ledger.filter(testRows)
        let inspectedIDs = Set((Array(sample.inside.prefix(2)) + Array(sample.outside.prefix(2))).map(\.id))
        let pending = try await ledger.pending()
        for item in pending where inspectedIDs.contains(item.id) {
            try Task.checkCancellation()
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject
            if let asset, asset.modificationDate?.timeIntervalSinceReferenceDate == item.modified {
                let evidence = await CameraEvidenceReader.read(asset)
                _ = try await ledger.record(evidence, for: item)
            }
        }

        func publish(_ scope: TravelScanScope) async throws -> (ids: Set<String>, reasons: [TravelScanDecision: Int]) {
            let identity = try await ledger.prepare(scope)
            let sweep = UUID().uuidString
            let members = try await ledger.filter(testRows, sweep: sweep)
            try await ledger.finishSweep(sweep)
            let sourceCount = try await ledger.sourceCount()
            let run = try await index.beginMetadataScan(copyCurrent: false)
            _ = try await index.stageMetadata(.init(records: members), run: run)
            let liveIndex = try await index.activateMetadata(run: run, sourcePhotoCount: sourceCount,
                token: Data([1]), fullCheck: true, authorization: identity.scope,
                configuration: .init(), catalog: try JourneyPlaceCatalog.shared) { _, _ in }
            let page = try await index.photoPage(for: liveIndex.places.map(\.id), offset: 0, limit: 48)
            let ids = Set(page.records.map(\.id))
            #expect(ids.count == liveIndex.locatedPhotoCount)
            #expect(page.nextOffset == nil)
            return (ids, try await ledger.counts())
        }

        let before = try await publish(base)
        let qualifyingInside = before.ids.intersection(insideIDs)
        let qualifyingOutside = before.ids.intersection(controls)
        try #require(!qualifyingInside.isEmpty && !qualifyingOutside.isEmpty, "Need eligible located photos on both sides of a regular album boundary.")
        let hidden = try await publish(excluded)
        let contentsMatch = hidden.ids == before.ids.subtracting(qualifyingInside)
        #expect(contentsMatch, "Excluding the album should remove exactly its eligible sample members.")
        #expect(hidden.ids.count == qualifyingOutside.count)
        #expect(hidden.reasons[.excludedAlbum, default: 0] == insideIDs.count)

        let restoredScope = try TravelScanScope.fetch(original, saveVerification: false)
        let sameOriginalScope = restoredScope.fingerprint == base.fingerprint
        try #require(sameOriginalScope, "The user's real library scope changed during the test.")
        let restored = try await publish(restoredScope)
        let restoredEverything = restored.ids == before.ids && restored.reasons == before.reasons
        #expect(restoredEverything, "Restoring the original selection must reproduce every member and reason count.")
        print("Real TV album scope: indexed \(before.ids.count) → \(hidden.ids.count) → \(restored.ids.count), album members \(qualifyingInside.count), controls \(qualifyingOutside.count), pending camera \(before.reasons[.pendingCamera, default: 0]).")
    }

    private struct Sample {
        let album: String
        let inside: [ScanAssetMetadata]
        let outside: [ScanAssetMetadata]
    }

    private enum SampleError: Error { case noReadableAlbumWithLocatedPhotosAndOutsideControls }

    private func findSample(_ base: TravelScanScope) throws -> Sample {
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        let images = PHAsset.fetchAssets(with: .image, options: nil)
        var inspected = Set<String>()
        for i in 0..<albums.count {
            try Task.checkCancellation()
            let album = albums.object(at: i)
            guard !base.preferences.excludedAlbums.contains(album.localIdentifier),
                  inspected.insert(album.localIdentifier).inserted else { continue }
            let contents = PHAsset.fetchAssets(in: album, options: nil)
            let inside = try candidates(contents, excluding: base.members)
            guard !inside.isEmpty else { continue }
            // Test-side ground truth is obtained from *this* PHAssetCollection.
            // Keep IDs only, never request an album's media to determine membership.
            var albumMembers = Set<String>()
            for j in 0..<contents.count {
                if j.isMultiple(of: 256) { try Task.checkCancellation() }
                autoreleasepool { _ = albumMembers.insert(contents.object(at: j).localIdentifier) }
            }
            let outside = try candidates(images, excluding: base.members.union(albumMembers))
            if !outside.isEmpty { return Sample(album: album.localIdentifier, inside: inside, outside: outside) }
        }
        throw SampleError.noReadableAlbumWithLocatedPhotosAndOutsideControls
    }

    private func candidates(_ assets: PHFetchResult<PHAsset>, excluding: Set<String>) throws -> [ScanAssetMetadata] {
        var result: [ScanAssetMetadata] = []
        var seen = Set<String>()
        for index in 0..<assets.count {
            try Task.checkCancellation()
            autoreleasepool {
                let asset = assets.object(at: index)
                guard asset.mediaType == .image, !excluding.contains(asset.localIdentifier),
                      !seen.contains(asset.localIdentifier) else { return }
                let metadata = ScanAssetMetadata(asset)
                guard metadata.record != nil else { return }
                seen.insert(metadata.id)
                result.append(metadata)
            }
            if result.count == 12 { break }
        }
        return result
    }
}
#endif
