import Foundation
import Photos
import TVServices

nonisolated enum JourneyShelfSelection {
    struct City: Equatable {
        let representative: TravelPlace
        let collection: PlaceCollection
    }

    static func recent(in index: TravelIndex, minimumVisitItems: Int) -> [City] {
        let representatives = PlaceCollection.homeCityRepresentatives(index.places, minimumVisitItems: minimumVisitItems)
        return representatives.prefix(JourneyShelfSnapshot.limit).map { place in
            let city = PlaceCollection.city(containing: place, in: index.places)
            let members = city.places.flatMap {
                [$0.id, String($0.coordinate.latitude.bitPattern), String($0.coordinate.longitude.bitPattern)]
            }
            let route = JourneyShelfLink.digest(["recent-city", place.id] + members)
            let label = PlaceDisplayLabel(place: place)
            let wall = PlaceCollection(id: route, title: city.title, subtitle: label.displaySubtitle,
                                       places: city.places, scope: city.scope)
            return City(representative: place, collection: wall)
        }
    }
}

@MainActor final class JourneyShelfPublication {
    private var worker: Task<Void, Never>?
    private var globeTask: Task<Void, Never>?
    private var pendingGlobeScope: String?
    private var posterTask: Task<Void, Never>?
    private var pendingPosters: JourneyShelfSnapshot?
    private var generation = JourneyShelfGeneration()
    private var hasPublishedInSession = false

    func suspendSelection() {
        hasPublishedInSession = false
        worker?.cancel()
        worker = nil
    }

    @discardableResult func clear() -> Bool {
        hasPublishedInSession = false
        _ = generation.advance()
        worker?.cancel()
        worker = nil
        globeTask?.cancel()
        globeTask = nil
        pendingGlobeScope = nil
        posterTask?.cancel()
        posterTask = nil
        pendingPosters = nil
        let cleared = JourneyShelfKeychain.write(nil)
        let clearedGlobe = JourneyShelfKeychain.writeGlobe(nil)
        let clearedPosters = (0..<JourneyShelfSnapshot.limit).map { JourneyShelfKeychain.writePoster(nil, at: $0) }
        TVTopShelfContentProvider.topShelfContentDidChange()
        return cleared && clearedGlobe && !clearedPosters.contains(false)
    }

    func removeCovers(in ids: Set<String>) {
        guard var snapshot = JourneyShelfKeychain.read(), snapshot.items.contains(where: { ids.contains($0.assetID) }) else { return }
        snapshot.items.removeAll { ids.contains($0.assetID) }
        if snapshot.items.isEmpty { clear(); return }
        _ = generation.advance()
        worker?.cancel()
        globeTask?.cancel()
        posterTask?.cancel()
        pendingGlobeScope = nil
        pendingPosters = nil
        if !JourneyShelfKeychain.write(snapshot) { clear(); return }
        JourneyShelfKeychain.writeGlobe(nil)
        for slot in 0..<JourneyShelfSnapshot.limit where JourneyShelfKeychain.poster(at: slot, in: snapshot) == nil {
            JourneyShelfKeychain.writePoster(nil, at: slot)
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    func refresh(_ model: AppModel, index: TravelIndex, store: SQLiteTravelIndexStore) {
#if DEBUG
        let started = CityCoverTimingQA.now
#endif
        let ticket = generation.advance()
        worker?.cancel()
        worker = Task { [weak self, weak model] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, let model else { return }
            guard let status = JourneyShelfPhoto.access(), let token = try? await store.loadSyncState().token else {
                if self.generation.current == ticket { self.clear() }
                return
            }
            let excluded = TravelScanPreferences.load().excludedAlbums
            let minimum = model.minimumJourneyItems
            let scanScope = JourneyShelfLink.digest([index.contentRevision, String(minimum)]
                + excluded.sorted() + model.excludedAssetIDs.sorted())
            let cities = JourneyShelfSelection.recent(in: index, minimumVisitItems: minimum)
            let representatives = cities.map(\.representative)
            let ids = Set(representatives.compactMap(\.offlinePlaceID))
            async let titles = JourneyPlaceCatalog.shared.shelfTitles(
                for: ids, languages: AppLocalization.SupportedLanguage.allCases.map(\.rawValue))
            var held: [String: String] = [:]
            if self.hasPublishedInSession, let previous = JourneyShelfKeychain.read() {
                for selected in cities {
                    if let item = previous.items.first(where: { $0.route == selected.collection.id && $0.awaitingCover != true }) {
                        held[selected.representative.id] = item.assetID
                    }
                }
            }
            let savedCovers = await model.savedVisitCovers(for: representatives, keeping: held)
            guard !Task.isCancelled else { return }
            var entries: [String: JourneyShelfItem] = [:]

            @MainActor func entry(for id: String, in selected: JourneyShelfSelection.City) async -> JourneyShelfItem? {
                guard !Task.isCancelled, !model.excludedAssetIDs.contains(id),
                      let cover = try? await store.visibleJourneyCover(id, in: [selected.representative.id]),
                      !model.excludedAssetIDs.contains(id) else { return nil }
                return await Self.entry(collection: selected.collection, cover: cover, excluding: excluded)
            }

            var missing: [JourneyShelfSelection.City] = []
            for selected in cities {
                guard !Task.isCancelled else { return }
                if let saved = savedCovers[selected.representative.id],
                   let cached = await entry(for: saved.assetID, in: selected) {
                    entries[selected.collection.id] = cached
                } else {
                    missing.append(selected)
                }
            }
            // The latest item provides the existing selection algorithm's fallback
            // and the membership proof for placeholder artwork.
            var latest: [String: PhotoPreviewMetadata] = [:]
            for start in stride(from: 0, to: missing.count, by: 15) {
                guard !Task.isCancelled else { return }
                let batch = missing[start..<min(start + 15, missing.count)]
                let previews = (try? await model.latestPhotoPreviews(for: batch.map(\.representative))) ?? [:]
                latest.merge(previews) { _, newer in newer }
                for selected in batch {
                    if let cover = previews[selected.representative.id],
                       var pending = await entry(for: cover.assetID, in: selected) {
                        pending.awaitingCover = true
                        entries[selected.collection.id] = pending
                    }
                }
            }
            let shelfTitles = (try? await titles) ?? [:]

            @MainActor func publish() -> Bool {
                guard !Task.isCancelled, model.minimumJourneyItems == minimum, self.generation.accepts(ticket, enabled: model.showsJourneysOnTopShelf,
                    live: model.usesLivePhotoLibrary, currentRevision: model.index?.contentRevision, sourceRevision: index.contentRevision) else { return false }
                let items = cities.compactMap { selected -> JourneyShelfItem? in
                    guard var item = entries[selected.collection.id], !model.excludedAssetIDs.contains(item.assetID) else { return nil }
                    item.endDate = selected.representative.endDate
                    item.localizedTitles = selected.representative.offlinePlaceID.flatMap { shelfTitles[$0] }
                    item.regionCode = selected.representative.regionCode
                    return item
                }
                let snapshot = JourneyShelfSnapshot(sectionTitle: AppLocalization.string("home.recent_arrivals", defaultValue: "Recently Visited Cities"),
                                                   historyToken: token, limitedAccess: status == .limited, items: items, imageVersion: JourneyShelfSnapshot.currentImageVersion,
                                                   scanScope: scanScope, globePeriod: Int(Date().timeIntervalSince1970 / 21_600),
                                                   excludedAlbumMask: JourneyShelfSnapshot.albumMask(excluded))
                let validity = JourneyShelfPhoto.delivery(snapshot)
                guard validity.history == .current else {
                    if !validity.readable { self.clear() }
                    return false
                }
                if items.isEmpty {
                    // A different, readable candidate may still be found by the second phase.
                    if JourneyShelfKeychain.read() != nil {
                        JourneyShelfKeychain.write(nil)
                        JourneyShelfKeychain.writeGlobe(nil)
                        for slot in 0..<JourneyShelfSnapshot.limit { JourneyShelfKeychain.writePoster(nil, at: slot) }
                        TVTopShelfContentProvider.topShelfContentDidChange()
                    }
                } else if JourneyShelfKeychain.read() != snapshot, JourneyShelfKeychain.write(snapshot) {
                    TVTopShelfContentProvider.topShelfContentDidChange()
                }
                if !items.isEmpty, JourneyShelfKeychain.read() == snapshot {
                    self.hasPublishedInSession = true
                    self.prepareGlobe(for: snapshot, model: model)
                    self.preparePosters(for: snapshot)
                }
                return true
            }

            guard publish() else { return }
#if DEBUG
            CityCoverTimingQA.recordPublication("initialPublication", since: started, itemCount: entries.count)
#endif
            var hasChanges = false
            var hasPublishedCover = entries.values.contains { $0.awaitingCover != true }
            for (offset, selected) in cities.enumerated() {
                guard !Task.isCancelled else { return }
#if DEBUG
                if offset == PlaceCollection.homeRecentLimit {
                    CityCoverTimingQA.recordPublication("firstFiveEvaluated", since: started, itemCount: entries.count)
                }
#endif
                if offset == PlaceCollection.homeRecentLimit, hasChanges {
                    guard publish() else { return }
                    hasChanges = false
                }
                let city = selected.collection
                if let ready = entries[city.id], ready.awaitingCover != true { continue }
                let fallback = latest[selected.representative.id]
                let cover = await model.preferredVisitCover(for: selected.representative, fallback: fallback)
                guard !Task.isCancelled else { return }
                var resolved: JourneyShelfItem?
                if let cover { resolved = await entry(for: cover.assetID, in: selected) }
                guard !Task.isCancelled else { return }
                if resolved == nil, entries[city.id]?.awaitingCover != true { continue }
                guard entries[city.id] != resolved else { continue }
                entries[city.id] = resolved
                hasChanges = true
                if !hasPublishedCover, resolved != nil {
                    guard publish() else { return }
                    hasPublishedCover = true
                    hasChanges = false
                }
            }
            if hasChanges { _ = publish() }
#if DEBUG
            CityCoverTimingQA.recordPublication("allEvaluated", since: started, itemCount: entries.count)
#endif
        }
    }

    private func preparePosters(for snapshot: JourneyShelfSnapshot) {
        guard pendingPosters != snapshot else { return }
        posterTask?.cancel()
        pendingPosters = snapshot
        posterTask = Task { [weak self] in
            guard let self else { return }
            defer { if pendingPosters == snapshot { pendingPosters = nil; posterTask = nil } }
            let resolvedAssets = snapshot.items.filter { $0.awaitingCover != true }.map(\.assetID)
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: resolvedAssets, options: nil)
            var byID: [String: PHAsset] = [:]
            assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
            var missing: [Int] = []
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            func prepare(_ slot: Int, network: Bool) async -> Bool {
                guard !Task.isCancelled, .now < deadline, JourneyShelfKeychain.read() == snapshot,
                      JourneyShelfPhoto.isCurrent(snapshot) else { return false }
                let item = snapshot.items[slot]
                guard let asset = byID[item.assetID], JourneyShelfPhoto.proof(for: asset) == item.photoProof else { return false }
                if JourneyShelfKeychain.poster(at: slot, in: snapshot) != nil { return true }
                guard let bytes = await ShelfPreviewRequest().jpegFromOriginal(asset: asset, network: network, deadline: deadline),
                      !Task.isCancelled, JourneyShelfKeychain.read() == snapshot, JourneyShelfPhoto.isCurrent(snapshot),
                      JourneyShelfPhoto.proof(for: asset) == item.photoProof else { return false }
                return JourneyShelfKeychain.writePoster(bytes, at: slot, in: snapshot)
            }
            var added = false
            for slot in 0..<JourneyShelfSnapshot.limit {
                guard !Task.isCancelled, JourneyShelfKeychain.read() == snapshot else { return }
                if JourneyShelfKeychain.poster(at: slot, in: snapshot) != nil { continue }
                JourneyShelfKeychain.writePoster(nil, at: slot)
                if snapshot.items.indices.contains(slot), snapshot.items[slot].awaitingCover != true {
                    if await prepare(slot, network: false) { added = true } else { missing.append(slot) }
                }
            }
            for slot in missing.prefix(5) where !Task.isCancelled {
                if await prepare(slot, network: true) { added = true }
            }
            if added, !Task.isCancelled, JourneyShelfKeychain.read() == snapshot {
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
        }
    }

    private func prepareGlobe(for snapshot: JourneyShelfSnapshot, model: AppModel) {
        guard let scope = snapshot.globeScope, pendingGlobeScope != scope else { return }
        globeTask?.cancel()
        guard JourneyShelfKeychain.globe(for: scope) == nil else { return }
        JourneyShelfKeychain.writeGlobe(nil)
        pendingGlobeScope = scope
        globeTask = Task { [weak self, weak model] in
            guard let self else { return }
            defer { if pendingGlobeScope == scope { pendingGlobeScope = nil; globeTask = nil } }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let markers = snapshot.markerItems
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: markers.map(\.assetID), options: nil)
            var byID: [String: PHAsset] = [:]
            assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
            var coordinates: [CLLocationCoordinate2D] = []
            for entry in markers {
                guard let asset = byID[entry.assetID],
                      JourneyShelfPhoto.proof(for: asset) == entry.photoProof,
                      let coordinate = asset.location?.coordinate else { return }
                coordinates.append(coordinate)
            }
            guard !Task.isCancelled, let image = await EarthShelfMapArtwork.render(coordinates: coordinates),
                  !Task.isCancelled, model?.showsJourneysOnTopShelf == true, model?.usesLivePhotoLibrary == true,
                  let current = JourneyShelfKeychain.read(), current.globeScope == scope,
                  JourneyShelfPhoto.validatesAllMarkers(current), JourneyShelfKeychain.writeGlobe(image, scope: scope) else { return }
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }

    private static func entry(collection: PlaceCollection, cover: PhotoAssetRecord, excluding albums: Set<String>) async -> JourneyShelfItem? {
        guard let placeID = cover.placeID, collection.placeIDs.contains(placeID) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [cover.id], options: nil).firstObject,
                  let date = asset.creationDate, abs(date.timeIntervalSince(cover.creationDate)) < 0.001,
                  let coordinate = asset.location?.coordinate, coordinate.latitude == cover.coordinate.latitude,
                  coordinate.longitude == cover.coordinate.longitude, let proof = JourneyShelfPhoto.proof(for: asset, excluding: albums)
            else { return nil }
            return JourneyShelfItem(route: collection.id, title: collection.title, assetID: cover.id, photoProof: proof, period: collection.subtitle)
        }.value
    }
}
