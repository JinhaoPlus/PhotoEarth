import Foundation
import Testing
@testable import PhotoEarth

@MainActor
struct OnlineMusicRecommendationTests {
    typealias Track = OnlineSlideshowPlaylist.Track

    private struct RepeatableRandom: RandomNumberGenerator {
        var state: UInt64 = 0xD1B54A32D192ED03

        nonisolated mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    private let catalog = (0..<9).map { category in
        let theme = "theme-\(category)"
        let tracks = (0..<8).map { number in
            let name = "\(theme)-\(number)"
            return Track(title: name, artist: "", url: URL(string: "https://example.org/\(name)")!, themeID: theme)
        }
        return OnlineSlideshowPlaylist(id: theme, tracks: tracks, presentation: nil)
    }

    @Test func coldStartCoversEveryCategoryTwiceAndKeepsUnheardTracksFirst() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstShow = OnlineMusicRecommendations(defaults: defaults)
        let list = firstShow.playlists(for: catalog)
        #expect(list.map(\.id) == [OnlineSlideshowPlaylist.recommendedID] + catalog.map(\.id))
        let tracks = list[0].tracks
        let themes = Set(catalog.map(\.id))
        #expect(tracks.count == 18 && Set(tracks.map(\.id)).count == 18)
        #expect(Set(tracks.prefix(9).map(\.themeID)) == themes)
        #expect(Set(tracks.suffix(9).map(\.themeID)) == themes)
        #expect(zip(tracks, tracks.dropFirst()).allSatisfy { $0.themeID != $1.themeID })
        tracks.forEach(firstShow.recordPlayback)
        #expect(firstShow.playlists(for: catalog)[0].tracks == tracks)
        let newShow = OnlineMusicRecommendations(defaults: defaults)
        let next = newShow.playlists(for: catalog)[0].tracks
        #expect(Set(next.map(\.id)).isDisjoint(with: Set(tracks.map(\.id))))
        #expect(Set(next.suffix(9).map(\.themeID)) == themes)
        // Refresh removes a withdrawn category without changing the rest of the frozen list.
        #expect(firstShow.playlists(for: Array(catalog.dropLast()))[0].tracks == tracks.filter { $0.themeID != catalog.last?.id })
    }

    @Test func recentChoicesFavorTheirOriginalThemeInBothRounds() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = OnlineMusicRecommendations(defaults: defaults)
        let favorite = catalog[0]
        let original = session.playlists(for: catalog)[0].tracks
        for _ in 0..<24 { session.recordChoice(favorite.tracks[0]) }
        #expect(session.playlists(for: catalog)[0].tracks == original)
        // A second controller reads the same device-local history.
        let otherSession = OnlineMusicRecommendations(defaults: defaults)
        var random = RepeatableRandom()
        var early = 0
        var extra = 0
        for _ in 0..<100 {
            otherSession.resetSession()
            let tracks = otherSession.playlists(for: catalog, using: &random)[0].tracks
            #expect(tracks.count == 18 && Set(tracks.map(\.id)).count == 18)
            #expect(Set(tracks.prefix(9).map(\.themeID)).count == 9)
            early += tracks.prefix(3).filter { $0.themeID == favorite.id }.count
            extra += tracks.suffix(9).filter { $0.themeID == favorite.id }.count
        }
        #expect(early > 55 && extra > 145)
    }
}
