import Foundation
import Testing
@testable import PhotoEarth

struct JourneyShelfFormatTests {
    @Test func extensionRejectsStoredDistrictTitlesUntilHostPublishesTheCurrentCatalog() throws {
        let digest = JourneyShelfLink.digest(["visit"])
        var snapshot = JourneyShelfSnapshot(sectionTitle: "Recently Visited Cities", historyToken: Data([1]),
            limitedAccess: false, items: [.init(route: digest, title: "Nanshan", assetID: "asset", photoProof: digest)],
            imageVersion: JourneyShelfSnapshot.currentImageVersion, scanScope: digest)
        snapshot.catalogRevision = nil
        let legacyBytes = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: legacyBytes, as: UTF8.self).contains("catalogRevision"))
        #expect(JourneyShelfSnapshot.decodePublication(legacyBytes) == nil)
        snapshot.catalogRevision = "world-atlas-20261121.4"
        #expect(JourneyShelfSnapshot.decodePublication(try JSONEncoder().encode(snapshot)) == nil)
        let current = JourneyShelfSnapshot(sectionTitle: snapshot.sectionTitle, historyToken: snapshot.historyToken,
            limitedAccess: false, items: [.init(route: digest, title: "Shenzhen", assetID: "asset", photoProof: digest)],
            imageVersion: JourneyShelfSnapshot.currentImageVersion, scanScope: digest)
        let restored = try #require(JourneyShelfSnapshot.decodePublication(try JSONEncoder().encode(current)))
        #expect(restored.items.map(\.title) == ["Shenzhen"])
        #expect(restored.catalogRevision == WorldCityAtlas.revision)
    }

    @Test func pendingRouteCannotReadOrWriteArtworkUntilSelectionIsResolved() throws {
        let digest = JourneyShelfLink.digest
        let item = JourneyShelfItem(route: digest(["city"]), title: "City", assetID: "latest", photoProof: digest(["latest"]))
        var snapshot = JourneyShelfSnapshot(sectionTitle: "Trips", historyToken: Data([1]), limitedAccess: false, items: [item],
                                            imageVersion: JourneyShelfSnapshot.currentImageVersion, scanScope: digest(["scope"]))
        snapshot.items[0].awaitingCover = true
        let restored = try JSONDecoder().decode(JourneyShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.eligiblePosters(proofs: ["latest": item.photoProof]).first?.item.route == item.route)
        #expect(restored.posterScope(at: 0) == nil)
        snapshot.items[0] = item
        #expect(snapshot.posterScope(at: 0) != nil)
    }

    @Test func artworkBelongsToItsCurrentScanHistoryAndOrderedApprovedMarkers() throws {
        let digest = JourneyShelfLink.digest
        let a = JourneyShelfItem(route: digest(["A"]), title: "A", assetID: "a", photoProof: digest(["photo A"]))
        let b = JourneyShelfItem(route: digest(["B"]), title: "B", assetID: "b", photoProof: digest(["photo B"]))
        func scope(_ items: [JourneyShelfItem], _ filter: String = "albums A", _ history: UInt8 = 1,
                   _ limited: Bool = false, _ version: Int = JourneyShelfSnapshot.currentImageVersion) -> String? {
            JourneyShelfSnapshot(sectionTitle: "Trips", historyToken: Data([history]), limitedAccess: limited, items: items,
                                 imageVersion: version, scanScope: digest([filter])).globeScope
        }
        let original = try #require(scope([a, b]))
        #expect(scope([a,b]) == original)
        #expect(scope([a]) != original)
        #expect(scope([b,a]) != original)
        #expect(scope([a,b], "new exclusion") != original)
        #expect(scope([a,b], "albums A", 2) != original)
        #expect(scope([a,b], "albums A", 1, true) != original)
        #expect(scope([a,b], "albums A", 1, false, JourneyShelfSnapshot.currentImageVersion - 1) == nil)
        #expect(scope([]) == nil)
        let visibleMarkers = (0..<JourneyShelfSnapshot.globeMarkerLimit).map { i in
            JourneyShelfItem(route: digest(["card", String(i)]), title: "City", assetID: "photo-\(i)", photoProof: digest([String(i)]))
        }
        #expect(scope(visibleMarkers + [a]) == scope(visibleMarkers + [b]))
        #expect(scope([a] + visibleMarkers) != scope([b] + visibleMarkers))
    }

    @Test func thePublicGlobeAlwaysOpensAndPrivateRoutesRespectTheCurrentSetting() throws {
        let globe = JourneyShelfDestination.globeURL
        #expect(JourneyShelfDestination(url: globe, showsJourneys: false) == .globe)
        #expect(JourneyShelfDestination(url: globe, showsJourneys: true) == .globe)
        let route = JourneyShelfLink.digest(["earlier-journey"])
        let existing = try #require(JourneyShelfLink.url(route))
        #expect(JourneyShelfDestination(url: existing, showsJourneys: true) == .journey(route))
        #expect(JourneyShelfDestination(url: existing, showsJourneys: false) == nil)
        for text in ["photoearth://globe?latitude=0", "photoearth://globe/extra", "https://globe"] {
            let unknown = try #require(URL(string: text))
            #expect(JourneyShelfDestination(url: unknown, showsJourneys: true) == nil)
        }
    }

    @Test func linksAcceptOnlyTheCanonicalPublishedRoute() throws {
        let digest = JourneyShelfLink.digest(["trip", "visit"])
        let url = try #require(JourneyShelfLink.url(digest))
        #expect(JourneyShelfLink.route(url) == digest)
        for value in ["photoearth://journey/other", "https://journey/" + digest,
                      url.absoluteString + "?place=outside", url.absoluteString + "/extra",
                      "photoearth://other/" + digest] {
            #expect(JourneyShelfLink.route(try #require(URL(string: value))) == nil)
        }
        #expect(JourneyShelfLink.digest(["a", "bc"]) != JourneyShelfLink.digest(["ab", "c"]))
    }

    @Test func onlyDuplicateVisibleTitlesGetTheirTripDates() {
        let a = JourneyShelfItem(route: "a", title: "Tokyo", assetID: "1", photoProof: "", period: "Jan 9–12")
        let b = JourneyShelfItem(route: "b", title: "Tokyo", assetID: "2", photoProof: "", period: "Oct 3–5")
        let c = JourneyShelfItem(route: "c", title: "Kyoto", assetID: "3", photoProof: "", period: "Feb 8")
        let d = JourneyShelfItem(route: "d", title: "Mar 3", assetID: "4", photoProof: "", period: "Mar 3")
        let e = JourneyShelfItem(route: "e", title: "Mar 3", assetID: "5", photoProof: "", period: "Mar 3")
        #expect(JourneyShelfItem.displayTitles(in: [a,b,c]) == ["a": "Tokyo · Jan 9–12", "b": "Tokyo · Oct 3–5", "c": "Kyoto"])
        #expect(JourneyShelfItem.displayTitles(in: [a,c])["a"] == "Tokyo")
        #expect(JourneyShelfItem.displayTitles(in: [d,e])["d"] == "Mar 3")
        #expect(a.title == "Tokyo")
    }

    @Test func missingPosterDoesNotDemoteAJourneyAndChangedProofRemovesItsPrivateRow() {
        let digest = JourneyShelfLink.digest
        let older = JourneyShelfItem(route: digest(["old"]), title: "Old", assetID: "old", photoProof: digest(["proofOld"]), endDate: Date(timeIntervalSince1970: 1))
        let newest = JourneyShelfItem(route: digest(["new"]), title: "New", assetID: "new", photoProof: digest(["proofNew"]), endDate: Date(timeIntervalSince1970: 2))
        let value = JourneyShelfSnapshot(sectionTitle: "Trips", historyToken: Data([1]), limitedAccess: false,
                                        items: [older,newest], imageVersion: JourneyShelfSnapshot.currentImageVersion, scanScope: digest(["scope"]))
        let both = value.eligiblePosters(proofs: ["old":older.photoProof, "new":newest.photoProof])
        #expect(both.map(\.item.route) == [newest.route,older.route])
        #expect(both.map(\.slot) == [1,0])
        #expect(value.eligiblePosters(proofs: ["old":older.photoProof,"new":"updated"]).map(\.item.route) == [older.route])
        #expect(value.posterScope(at: 0) != value.posterScope(at: 1))
        #expect(value.posterScope(at: 2) == nil)
    }

    @Test func sharedPublicationRejectsPartialCorruptOrOverBudgetInput() {
        let digest = JourneyShelfLink.digest(["trip"])
        let item = JourneyShelfItem(route: digest, title: "Trip", assetID: "preview", photoProof: digest)
        func valid(_ items: [JourneyShelfItem], history: Data = Data([1])) -> Bool {
            JourneyShelfSnapshot(sectionTitle: "Trips", historyToken: history, limitedAccess: false, items: items).valid
        }
        #expect(valid([item]))
        #expect(!valid([]))
        #expect(!valid([item, item]))
        #expect(!valid([item], history: Data()))
        let tooMany = (0...JourneyShelfSnapshot.limit).map { index in
            JourneyShelfItem(route: JourneyShelfLink.digest(["\(index)"]), title: "Trip", assetID: "x", photoProof: digest)
        }
        #expect(!valid(tooMany))
    }

    @Test func disabledOrChangedSourcesInvalidateInFlightPublications() {
        var state = JourneyShelfGeneration()
        let first = state.advance()
        #expect(state.accepts(first, enabled: true, live: true, currentRevision: "A", sourceRevision: "A"))
        #expect(!state.accepts(first, enabled: false, live: true, currentRevision: "A", sourceRevision: "A"))
        #expect(!state.accepts(first, enabled: true, live: false, currentRevision: "A", sourceRevision: "A"))
        #expect(!state.accepts(first, enabled: true, live: true, currentRevision: "B", sourceRevision: "A"))
        let second = state.advance()
        #expect(!state.accepts(first, enabled: true, live: true, currentRevision: "A", sourceRevision: "A"))
        #expect(state.accepts(second, enabled: true, live: true, currentRevision: "A", sourceRevision: "A"))
    }

    @Test func unrelatedLibraryUpdatesKeepCardsWhileHiddenDeletedAndMovedAssetsAreWithdrawn() {
        let item = JourneyShelfItem(route: "trip", title: "Trip", assetID: "cover", photoProof: "current photo evidence")
        let unrelated = JourneyShelfPhoto.Delivery(history: .changesPending, touched: ["another-asset"])
        #expect(unrelated.permits(item, proof: item.photoProof))
        #expect(!unrelated.permits(item, proof: nil))
        #expect(!unrelated.permits(item, proof: "edited GPS"))
        let updated = JourneyShelfPhoto.Delivery(history: .changesPending, touched: ["cover"])
        #expect(updated.permits(item, proof: item.photoProof))
        #expect(!updated.permits(item, proof: "new GPS or revision"))
        let deleted = JourneyShelfPhoto.Delivery(history: .changesPending, touched: ["cover"], deletedCovers: ["cover"])
        #expect(!deleted.permits(item, proof: item.photoProof))
        for state in [JourneyShelfPhoto.History.noAccess, .accessChanged, .missingToken, .invalidToken, .unreadableHistory] {
            #expect(!JourneyShelfPhoto.Delivery(history: state).permits(item, proof: item.photoProof))
        }
        #expect(!JourneyShelfPhoto.Delivery(history: .changesPending, uncertainScope: true).permits(item, proof: item.photoProof))
        let snapshot = JourneyShelfSnapshot(sectionTitle: "Trips", historyToken: Data([1]), limitedAccess: false, items: [],
                                           excludedAlbumMask: JourneyShelfSnapshot.albumMask(["excluded"]))
        #expect(snapshot.mayHaveChangedExcludedAlbum(["excluded"]))
        #expect(!snapshot.mayHaveChangedExcludedAlbum(["different"]))
        #expect(!snapshot.mayHaveChangedExcludedAlbum([]))
    }
}
