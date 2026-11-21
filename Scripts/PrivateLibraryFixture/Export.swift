import AppKit
import Photos

@main enum Export {
    static func writeResource(_ resource: PHAssetResource, to url: URL, allowNetwork: Bool) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
    }

    static func export(_ asset: PHAsset, key: String, directory: URL, allowNetwork: Bool) async throws -> SampleItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let video = asset.mediaType == .video
        let live = asset.mediaSubtypes.contains(.photoLive)
        let types: [PHAssetResourceType] = video ? [.video] : live ? [.photo, .pairedVideo] : [.photo]
        var files: [String] = []
        for (i, type) in types.enumerated() {
            guard let resource = resources.first(where: { $0.type == type }) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension
            let filename = "\(key)-\(i).\(ext)"
            let dest = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: dest.path) {
                let temp = directory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                try await writeResource(resource, to: temp, allowNetwork: allowNetwork)
                try FileManager.default.moveItem(at: temp, to: dest)
            }
            files.append(filename)
        }
        let point = asset.location?.coordinate
        return SampleItem(key: key, date: asset.creationDate!, latitude: point?.latitude, longitude: point?.longitude,
                          favorite: asset.isFavorite, kind: video ? "video" : live ? "live" : "photo",
                          screenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                          recording: asset.mediaSubtypes.contains(.videoScreenRecording), files: files, albums: [])
    }

    // Spread short consecutive runs across the year, including real bursts and quiet months.
    static func candidateOrder(count: Int) -> [Int] {
        let groupCount = (count + 3) / 4
        guard groupCount > 0 else { return [] }
        var stride = max(1, Int(Double(groupCount) * 0.618))
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        while gcd(stride, groupCount) != 1 { stride += 1 }
        return (0..<groupCount).flatMap { group -> [Int] in
            let start = ((group * stride) % groupCount) * 4
            return Array(start..<min(start + 4, count))
        }
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let target = Int(args[2]), target >= 0,
              let year = Int(args[3]), (1900...9998).contains(year) else {
            FileHandle.standardError.write(Data("Usage: PhotoEarthLibrarySample PRIVATE_DIRECTORY SAMPLE_SIZE END_YEAR\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let calendar = Calendar(identifier: .gregorian)
        let log = directory.appendingPathComponent("export-progress.txt")
        func status(_ message: String) { try? message.write(to: log, atomically: true, encoding: .utf8) }
        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized else { status("Access status \(access.rawValue)"); return }
        let all = PHAsset.fetchAssets(with: nil)
        var totals: [String: Int] = [:]
        var years: [String: Int] = [:]
        var selectedMembership = Set<String>()
        var overlaps = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        for n in 0..<collections.count {
            let members = PHAsset.fetchAssets(in: collections.object(at: n), options: nil)
            for i in 0..<members.count {
                let id = members.object(at: i).localIdentifier
                if !selectedMembership.insert(id).inserted { overlaps.insert(id) }
            }
        }
        for i in 0..<all.count {
            autoreleasepool {
                let asset = all.object(at: i)
                let kind = asset.mediaType == .video ? "video" : asset.mediaSubtypes.contains(.photoLive) ? "live" : asset.mediaType == .image ? "photo" : "other"
                totals[kind, default: 0] += 1
                if asset.location != nil { totals["located", default: 0] += 1 }
                if asset.mediaSubtypes.contains(.photoScreenshot) { totals["screenshot", default: 0] += 1 }
                if asset.mediaSubtypes.contains(.videoScreenRecording) { totals["recording", default: 0] += 1 }
                if asset.isFavorite { totals["favorite", default: 0] += 1 }
                if let date = asset.creationDate { years[String(calendar.component(.year, from: date)), default: 0] += 1 }
            }
        }
        let census: [String: Any] = ["visibleAssets": all.count, "years": years, "types": totals, "regularAlbums": collections.count,
                                     "assetsInRegularAlbums": selectedMembership.count, "assetsInMultipleRegularAlbums": overlaps.count]
        try JSONSerialization.data(withJSONObject: census, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("library-summary.json"), options: .atomic)
        guard target > 0 else { status("Library summary complete"); return }
        var items: [SampleItem] = []
        var indexByID: [String: Int] = [:]
        var attempts = 0
        var savedCount = 0
        for offset in 0..<3 {
            let start = calendar.date(from: .init(year: year - 2 + offset, month: 1, day: 1))!
            let end = calendar.date(byAdding: .year, value: 1, to: start)!
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND (mediaType == %d OR mediaType == %d)", start as NSDate, min(end, Date()) as NSDate, PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: options)
            let base = items.count
            let limit = (target - base + 2 - offset) / (3 - offset)
            var candidates = candidateOrder(count: assets.count)
            for network in [false, true] {
                var unavailable: [Int] = []
                var cursor = 0
                while cursor < candidates.count && items.count - base < limit {
                    let width = min(6, limit - (items.count - base), candidates.count - cursor)
                    let indices = Array(candidates[cursor..<(cursor + width)])
                    let results = await withTaskGroup(of: (Int, SampleItem?).self) { group in
                        for i in indices {
                            let asset = assets.object(at: i)
                            let key = asset.localIdentifier.components(separatedBy: "/")[0]
                            group.addTask {
                                (i, try? await export(asset, key: key, directory: directory, allowNetwork: network))
                            }
                        }
                        var batch: [Int: SampleItem] = [:]
                        for await (i, row) in group { batch[i] = row }
                        return batch
                    }
                    for i in indices {
                        if let row = results[i] {
                            indexByID[assets.object(at: i).localIdentifier] = items.count
                            items.append(row)
                        } else { unavailable.append(i) }
                    }
                    if items.count - savedCount >= 100 {
                        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("sample.partial.json"), options: .atomic)
                        savedCount = items.count
                    }
                    attempts += width
                    cursor += width
                    status("Year \(year-2+offset), available \(assets.count), exported \(items.count), attempted \(attempts), iCloud allowed \(network)")
                }
                candidates = unavailable
            }
        }
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        for ordinal in 0..<albums.count {
            let members = PHAsset.fetchAssets(in: albums.object(at: ordinal), options: nil)
            for index in 0..<members.count {
                if let n = indexByID[members.object(at: index).localIdentifier] { items[n].albums.append(ordinal) }
            }
        }
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        status("Finished \(items.count) of \(target); attempted \(attempts)")
    }
}
