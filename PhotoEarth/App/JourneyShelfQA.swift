#if DEBUG
import Foundation
import ImageIO
import Photos

/// Explicit TV acceptance only. No asset identifiers, locations or titles leave SQLite.
@MainActor final class JourneyShelfQA {
    var receivedRoute: String?
    var openedRoute: String?
    private var task: Task<Void, Never>?

    func pause() { task?.cancel(); task = nil }

    func observe(_ model: AppModel, store: SQLiteTravelIndexStore?) {
        guard ProcessInfo.processInfo.arguments.contains("--qa-shelf-report") else { return }
        pause()
        task = Task { [weak self, weak model] in
            for _ in 0..<90 {
                guard !Task.isCancelled, let self, let model else { return }
                await self.write(model, store: store)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func write(_ model: AppModel, store: SQLiteTravelIndexStore?) async {
        let sourceToken = try? await store?.loadSyncState().token
        guard !Task.isCancelled else { return }
        let snapshot = JourneyShelfKeychain.read()
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let recent = model.index.map { JourneyShelfSelection.recent(in: $0, minimumVisitItems: model.minimumJourneyItems) } ?? []
        let phase: String
        switch model.phase {
        case .loading: phase = "loading"
        case .welcome: phase = "welcome"
        case .scanning: phase = "scanning"
        case .globe: phase = "globe"
        case .empty: phase = "empty"
        case .denied: phase = "denied"
        case .failed: phase = "failed"
        }
        let access: String
        switch authorization {
        case .authorized: access = "authorized"
        case .limited: access = "limited"
        case .denied: access = "denied"
        case .restricted: access = "restricted"
        case .notDetermined: access = "notDetermined"
        @unknown default: access = "unknown"
        }
        var report: [String: Any] = [
            "capturedAt": Date().timeIntervalSince1970, "phase": phase, "authorization": access,
            "enabled": model.showsJourneysOnTopShelf, "liveLibrary": model.usesLivePhotoLibrary,
            "minimumJourneyItems": model.minimumJourneyItems, "eligibleRecentCityCount": recent.count, "totalJourneys": model.index?.journeys.count ?? 0,
            "publicationCount": snapshot?.items.count ?? 0, "keychainStatus": JourneyShelfKeychain.readStatus(),
            "indexHistory": JourneyShelfPhoto.history(sourceToken, limited: authorization == .limited).rawValue,
            "publicationHistory": snapshot.map { JourneyShelfPhoto.history($0.historyToken, limited: $0.limitedAccess).rawValue } ?? "noPublication"
        ]
        let privateMap = snapshot.flatMap { value in
            model.showsJourneysOnTopShelf && JourneyShelfPhoto.validatesAllMarkers(value) ? value.globeScope.flatMap(JourneyShelfKeychain.globe(for:)) : nil
        }
        report["globeImageSource"] = snapshot == nil || !model.showsJourneysOnTopShelf ? "none" : (privateMap == nil ? "publicMapKit" : "privateNativeMap")
        report["globeScopeMatches"] = privateMap != nil
        report["globeRenderStage"] = EarthShelfMapArtwork.lastStage
        report["globeRenderPath"] = EarthShelfMapArtwork.renderingPath
        report["publishedCityLastVisitDates"] = snapshot?.items.compactMap { $0.endDate?.ISO8601Format() } ?? []
        report["preparedPosterCount"] = snapshot.map { value in
            value.items.indices.filter { JourneyShelfKeychain.poster(at: $0, in: value) != nil }.count
        } ?? 0
        let extensionBundle = Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("PhotoEarthTopShelf.appex")) }
        let image = privateMap ?? extensionBundle?.url(forResource: "EarthShelfGlobePreview", withExtension: "jpg").flatMap { try? Data(contentsOf: $0) }
        if let image, let source = CGImageSourceCreateWithData(image as CFData, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            report["globeJPEGBytes"] = image.count
            report["globePixelWidth"] = metadata[kCGImagePropertyPixelWidth]
            report["globePixelHeight"] = metadata[kCGImagePropertyPixelHeight]
        }
        if let route = snapshot?.items.first?.route { report["route"] = JourneyShelfLink.url(route)?.absoluteString }
        if let receivedRoute { report["lastReceivedRoute"] = receivedRoute }
        if let openedRoute { report["lastOpenedRoute"] = openedRoute }
        if let receipt = JourneyShelfKeychain.providerReceipt() {
            let fields = receipt.split(separator: " ")
            if fields.count >= 3, let timestamp = Double(fields[0]), let count = Int(fields[2]) {
                let status = String(fields[1])
                var provider: [String: Any] = ["at": timestamp, "status": status, "count": count, "returnedContent": count > 0]
                if status.hasPrefix("nil-") {
                    provider["suppressionReason"] = String(status.dropFirst(4))
                    if !model.showsJourneysOnTopShelf && status == "nil-no-current-publication" {
                        provider["currentHostSetting"] = "disabled"
                    }
                }
                if fields.count >= 4, let readable = Int(fields[3]) {
                    provider["readablePosters"] = readable
                    provider["neutralPosters"] = count - readable
                    provider["deliveredCityLastVisitDates"] = fields.dropFirst(4).first?.split(separator: ",").compactMap {
                        Double($0).map { Date(timeIntervalSince1970: $0).ISO8601Format() }
                    } ?? []
                }
                report["provider"] = provider
            }
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoEarth/ShelfQA", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? bytes.write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
    }
}
#endif
