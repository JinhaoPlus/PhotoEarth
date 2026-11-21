import Testing
@testable import PhotoEarth

struct PhotoBrowsingSessionTests {
    @Test func oneRightPressCrossesThe48PhotoPageBoundaryWithoutSkipping() {
        var session = PhotoBrowsingSession()
        let first = (1...48).map { "photo-\($0)" }
        #expect(session.update(ids: first, currentID: "photo-48") == nil)
        #expect(session.move(forward: true, hasMore: true) == .loadMore)
        #expect(session.waitsForNextPage)
        let appended = first + (49...96).map { "photo-\($0)" }
        #expect(session.update(ids: appended, currentID: "photo-48") == "photo-49")
        #expect(session.currentPosition == 48)
        #expect(!session.waitsForNextPage)
        #expect(session.move(forward: false, hasMore: true) == .photo("photo-48"))
        #expect(session.currentID == "photo-48")
    }

    @Test func reversingWhileNextPageLoadsCancelsItsPendingAdvance() {
        var session = PhotoBrowsingSession()
        let first = (1...48).map { "photo-\($0)" }
        _ = session.update(ids: first, currentID: "photo-48")
        #expect(session.move(forward: true, hasMore: true) == .loadMore)
        #expect(session.move(forward: false, hasMore: true) == .photo("photo-47"))
        #expect(session.update(ids: first + ["photo-49"], currentID: "photo-47") == nil)
        #expect(session.currentID == "photo-47")
    }

    @Test func emptyCandidatePagesDoNotConsumeThePendingMoveOrChangeTheAnchor() {
        var session = PhotoBrowsingSession()
        _ = session.update(ids: ["current"], currentID: "current")
        #expect(session.move(forward: true, hasMore: true) == .loadMore)
        #expect(session.update(ids: ["current"], currentID: "current") == nil)
        #expect(session.waitsForNextPage)
        session.cancelPendingAdvance()
        #expect(session.update(ids: ["current", "later"], currentID: "current") == nil)
        #expect(session.currentID == "current")
    }

    @Test func deletionRebuildsPositionsAndNeverResurrectsTheRemovedPhoto() {
        var session = PhotoBrowsingSession()
        _ = session.update(ids: ["newest", "removed", "current", "oldest"], currentID: "current")
        _ = session.update(ids: ["newest", "current", "oldest"], currentID: "current")
        #expect(session.currentPosition == 1)
        #expect(session.move(forward: false, hasMore: false) == .photo("newest"))
        #expect(session.positions["removed"] == nil)
    }

    @Test func orderIsPinnedAndNeighborPrefetchNeverExceedsTwoPhotos() {
        var session = PhotoBrowsingSession()
        // Same-date database IDs are already ordered by the reader. The detail
        // follows this input exactly; it never sorts by title or geocoded city.
        let ids = ["city-b-photo-a", "city-a-photo-b", "city-b-photo-c"]
        _ = session.update(ids: ids, currentID: ids[1])
        #expect(session.neighborIDs == [ids[0], ids[2]])
        #expect(session.move(forward: true, hasMore: false) == .photo(ids[2]))
        #expect(session.neighborIDs == [ids[1]])
        #expect(session.move(forward: true, hasMore: false) == .boundary)
        #expect(session.currentID == ids[2])
    }
}
