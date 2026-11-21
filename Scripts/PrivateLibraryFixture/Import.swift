#if targetEnvironment(simulator)
import SwiftUI
import Photos
import CoreLocation

@main struct FixtureApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Importing the private test library")
                .task { await FixtureImport().start() }
        }
    }
}

@MainActor final class FixtureImport {
    let library = PHPhotoLibrary.shared()
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var directory: URL { docs.appendingPathComponent("sample") }
    var progress: URL { docs.appendingPathComponent("import-progress.txt") }
    func start() async {
        do { try await run() }
        catch {
            let error = error as NSError
            status("Failed \(error.domain) \(error.code)")
        }
    }
    func status(_ text: String) { try? text.write(to: progress, atomically: true, encoding: .utf8) }
    func run() async throws {
        guard try String(contentsOf: docs.appendingPathComponent("fixture-simulator"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == ProcessInfo.processInfo.environment["SIMULATOR_UDID"] else {
            throw CocoaError(.userCancelled)
        }
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized else { status("Access \(access.rawValue)"); return }
        let rows = try JSONDecoder().decode([SampleItem].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let prefix = "Fixture-"
        var imported: [String: String] = [:]
        let assets = PHAsset.fetchAssets(with: nil)
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let files = PHAssetResource.assetResources(for: asset)
            guard let name = files.first(where: { $0.originalFilename.hasPrefix(prefix) })?.originalFilename else {
                throw CocoaError(.fileWriteFileExists)
            }
            let key = name.dropFirst(prefix.count).components(separatedBy: "_")[0]
            imported[key] = asset.localIdentifier
        }
        guard Set(rows.map(\.key)).count == rows.count else { throw CocoaError(.fileReadCorruptFile) }
        let existingOutsideManifest = Set(imported.keys).subtracting(rows.map(\.key)).count
        let pending = rows.filter { imported[$0.key] == nil }
        var failed = 0
        for start in stride(from: 0, to: pending.count, by: 24) {
            let batch = Array(pending[start..<min(pending.count, start + 24)])
            do { imported.merge(try await add(batch)) { a, _ in a } }
            catch {
                for row in batch {
                    do { imported.merge(try await add([row])) { a, _ in a } }
                    catch { failed += 1 }
                }
            }
            status("Imported \(imported.count) of \(rows.count), failed \(failed)")
        }
        let grouped = Dictionary(grouping: rows.flatMap { row in row.albums.compactMap { n in imported[row.key].map { (n, $0) } } }, by: { $0.0 })
        for (album, records) in grouped.sorted(by: { $0.key < $1.key }) {
            let name = "Sample Album \(album)"
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title == %@", name)
            let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
            let members = PHAsset.fetchAssets(withLocalIdentifiers: records.map { $0.1 }, options: nil)
            try await library.performChanges {
                let edit = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) } ?? .creationRequestForAssetCollection(withTitle: name)
                edit.addAssets(members)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in imported[row.key].map { ($0, row) } })
        // Photos can re-read original EXIF time zones after insertion. Reapply the
        // source library's edited dates once the new assets have been committed.
        let committed = PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil)
        var dateFixes: [String: Date] = [:]
        for index in 0..<committed.count {
            let asset = committed.object(at: index)
            if let row = byID[asset.localIdentifier],
               abs(asset.creationDate?.timeIntervalSince(row.date) ?? .infinity) > 0.01 {
                dateFixes[asset.localIdentifier] = row.date
            }
        }
        if !dateFixes.isEmpty {
            let dates = dateFixes
            let edits = PHAsset.fetchAssets(withLocalIdentifiers: Array(dates.keys), options: nil)
            try await library.performChanges {
                var changed = Set<String>()
                for index in 0..<edits.count {
                    let asset = edits.object(at: index)
                    if changed.insert(asset.localIdentifier).inserted, let date = dates[asset.localIdentifier] {
                        PHAssetChangeRequest(for: asset).creationDate = date
                    }
                }
            }
        }
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: byID.map { ($0.value.key, $0.key) }))
            .write(to: docs.appendingPathComponent("source-to-simulator.json"), options: .atomic)
        let all = PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil)
        var seen: Set<String> = []
        var mismatches: [String: Int] = [:]
        var yearCounts: [String: Int] = [:]
        var maxDateDifference: TimeInterval = 0
        var albumDifferences = 0
        for (ordinal, expected) in grouped {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title == %@", "Sample Album \(ordinal)")
            guard let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
            else { albumDifferences += expected.count; continue }
            let actual = PHAsset.fetchAssets(in: album, options: nil)
            var assetIDs = Set<String>()
            for n in 0..<actual.count { assetIDs.insert(actual.object(at: n).localIdentifier) }
            albumDifferences += assetIDs.symmetricDifference(expected.map { $0.1 }).count
        }
        var kinds: [String: Int] = [:]
        var located = 0
        for n in 0..<all.count {
            let asset = all.object(at: n)
            guard seen.insert(asset.localIdentifier).inserted, let row = byID[asset.localIdentifier] else { continue }
            let kind = asset.mediaType == .video ? "video" : asset.mediaSubtypes.contains(.photoLive) ? "live" : "photo"
            kinds[kind, default: 0] += 1
            if kind != row.kind { mismatches["kind", default: 0] += 1 }
            if let date = asset.creationDate {
                yearCounts[String(Calendar.current.component(.year, from: date)), default: 0] += 1
                let drift = abs(date.timeIntervalSince(row.date))
                maxDateDifference = max(maxDateDifference, drift)
                if drift > 0.01 { mismatches["date", default: 0] += 1 }
            } else { mismatches["date", default: 0] += 1 }
            if asset.isFavorite != row.favorite { mismatches["favorite", default: 0] += 1 }
            if asset.mediaSubtypes.contains(.photoScreenshot) != row.screenshot { mismatches["screenshot", default: 0] += 1 }
            if asset.mediaSubtypes.contains(.videoScreenRecording) != row.recording { mismatches["recording", default: 0] += 1 }
            if asset.location != nil { located += 1 }
            if let lat = row.latitude, let lon = row.longitude {
                let expected = CLLocation(latitude: lat, longitude: lon)
                if (asset.location?.distance(from: expected) ?? .infinity) > 2 { mismatches["location", default: 0] += 1 }
            } else if asset.location != nil { mismatches["location", default: 0] += 1 }
        }
        let summary: [String: Any] = ["expected": rows.count, "readBack": seen.count, "additionalPhotoKitRows": all.count - seen.count, "existingOutsideManifest": existingOutsideManifest, "yearCounts": yearCounts, "albumMembershipDifferences": albumDifferences, "maxDateDifferenceSeconds": maxDateDifference, "dateCorrections": dateFixes.count, "located": located, "media": kinds, "differences": mismatches, "albums": grouped.count, "failed": failed]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent("import-summary.json"), options: .atomic)
        status("Finished \(seen.count) of \(rows.count); failures \(failed)")
    }

    func add(_ rows: [SampleItem]) async throws -> [String: String] {
        let folder = directory
        final class Placeholders: @unchecked Sendable { var ids: [String: String] = [:] }
        let result = Placeholders()
        try await library.performChanges {
            for row in rows {
                let request = PHAssetCreationRequest.forAsset()
                for (i, file) in row.files.enumerated() {
                    let url = folder.appendingPathComponent(file)
                    let type: PHAssetResourceType = i == 1 ? .pairedVideo : row.kind == "video" ? .video : .photo
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "Fixture-\(row.key)_\(i).\(url.pathExtension)"
                    request.addResource(with: type, fileURL: url, options: options)
                }
                request.creationDate = row.date
                if let lat = row.latitude, let lon = row.longitude { request.location = CLLocation(latitude: lat, longitude: lon) }
                request.isFavorite = row.favorite
                result.ids[row.key] = request.placeholderForCreatedAsset?.localIdentifier
            }
        }
        return result.ids
    }
}
#endif
